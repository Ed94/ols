package server

import "core:odin/parser"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:fmt"
import "core:log"
import "core:strings"
import "core:path"
import "core:mem"
import "core:strconv"

import "shared:common"
import "shared:index"


bool_lit := "bool";
int_lit := "int";
string_lit := "string";

DocumentPositionContextHint :: enum {
    Completion,
    SignatureHelp,
    Definition,
};

DocumentPositionContext :: struct {
    file: ast.File,
    position: common.AbsolutePosition,
    function: ^ast.Node, //used to help with type resolving in function scope
    selector: ^ast.Expr, //used for completion
    identifier: ^ast.Node,
    field: ^ast.Expr, //used for completion
    call: ^ast.Expr, //used for signature help
    hint: DocumentPositionContextHint,
};

AstContext :: struct {
    locals: map [string] ^ast.Expr, //locals all the way to the document position
    globals: map [string] ^ast.Expr,
    file: ast.File,
    allocator: mem.Allocator,
    imports: [] Package, //imports for the current document
    current_package: string,
    document_package: string,
    use_globals: bool,
    use_locals: bool,
    call: ^ast.Expr, //used to determene the types for generics and the correct function for overloaded functions
};

make_ast_context :: proc(file: ast.File, imports: [] Package, package_name: string, allocator := context.temp_allocator) -> AstContext {

    ast_context := AstContext {
        locals = make(map [string] ^ast.Expr, 0, allocator),
        globals = make(map [string] ^ast.Expr, 0, allocator),
        file = file,
        imports = imports,
        use_locals = true,
        use_globals = true,
        document_package = package_name,
        current_package = package_name,
    };

    return ast_context;
}

tokenizer_error_handler :: proc(pos: tokenizer.Pos, msg: string, args: ..any) {

}

/*
    Walk through the type expression while both the call expression and specialization type are the same
 */

resolve_poly_spec :: proc {
    resolve_poly_spec_node,
    resolve_poly_spec_array,
    resolve_poly_spec_dynamic_array,
};

resolve_poly_spec_array :: proc(ast_context: ^AstContext, call_array: $A/[]^$T, spec_array: $D/[]^$K, poly_map: ^map[string]^ast.Expr) {

    if len(call_array) != len(spec_array) {
        return;
    }

    for elem, i in call_array {
        resolve_poly_spec(ast_context, elem, spec_array[i], poly_map);
    }

}

resolve_poly_spec_dynamic_array :: proc(ast_context: ^AstContext, call_array: $A/[dynamic]^$T, spec_array: $D/[dynamic]^$K, poly_map: ^map[string]^ast.Expr) {

    if len(call_array) != len(spec_array) {
        return;
    }

    for elem, i in call_array {
        resolve_poly_spec(ast_context, elem, spec_array[i],  poly_map);
    }

}

get_poly_node_to_expr :: proc(node: ^ast.Node) -> ^ast.Expr {

    using ast;

    switch v in node.derived {
    case Ident:
        return cast(^Expr)node;
    case:
        log.errorf("Unhandled poly to node kind %v", v);
    }

    return nil;
}

resolve_poly_spec_node :: proc(ast_context: ^AstContext, call_node: ^ast.Node, spec_node: ^ast.Node, poly_map: ^map[string]^ast.Expr) {

    /*
        Note(Daniel, uncertain about the switch cases being enough or too little)
    */

    using ast;

    if call_node == nil || spec_node == nil {
        return;
    }

    switch m in spec_node.derived {
    case Bad_Expr:
    case Ident:
    case Implicit:
    case Undef:
    case Basic_Lit:
    case Poly_Type:
        if expr := get_poly_node_to_expr(call_node); expr != nil {
            poly_map[m.type.name] = expr;
        }
    case Ellipsis:
        if n, ok := call_node.derived.(Ellipsis); ok {
            resolve_poly_spec(ast_context, n.expr, m.expr, poly_map);
        }
    case Tag_Expr:
        if n, ok := call_node.derived.(Tag_Expr); ok {
            resolve_poly_spec(ast_context, n.expr, m.expr, poly_map);
        }
    case Unary_Expr:
        if n, ok := call_node.derived.(Unary_Expr); ok {
            resolve_poly_spec(ast_context, n.expr, m.expr, poly_map);
        }
    case Binary_Expr:
        if n, ok := call_node.derived.(Binary_Expr); ok {
            resolve_poly_spec(ast_context, n.left, m.left, poly_map);
            resolve_poly_spec(ast_context, n.right, m.right, poly_map);
        }
    case Paren_Expr:
        if n, ok := call_node.derived.(Paren_Expr); ok {
            resolve_poly_spec(ast_context, n.expr, m.expr, poly_map);
        }
    case Selector_Expr:
        if n, ok := call_node.derived.(Selector_Expr); ok {
            resolve_poly_spec(ast_context, n.expr, m.expr, poly_map);
            resolve_poly_spec(ast_context, n.field, m.field, poly_map);
        }
    case Slice_Expr:
        if n, ok := call_node.derived.(Slice_Expr); ok {
            resolve_poly_spec(ast_context, n.expr, m.expr, poly_map);
            resolve_poly_spec(ast_context, n.low, m.low, poly_map);
            resolve_poly_spec(ast_context, n.high, m.high, poly_map);
        }
    case Distinct_Type:
        if n, ok := call_node.derived.(Distinct_Type); ok {
            resolve_poly_spec(ast_context, n.type, m.type, poly_map);
        }
    case Opaque_Type:
        if n, ok := call_node.derived.(Opaque_Type); ok {
            resolve_poly_spec(ast_context, n.type, m.type, poly_map);
        }
    case Proc_Type:
        if n, ok := call_node.derived.(Proc_Type); ok {
            resolve_poly_spec(ast_context, n.params, m.params, poly_map);
            resolve_poly_spec(ast_context, n.results, m.results, poly_map);
        }
    case Pointer_Type:
        if n, ok := call_node.derived.(Pointer_Type); ok {
            resolve_poly_spec(ast_context, n.elem, m.elem, poly_map);
        }
    case Array_Type:
        if n, ok := call_node.derived.(Array_Type); ok {
            resolve_poly_spec(ast_context, n.len, m.len, poly_map);
            resolve_poly_spec(ast_context, n.elem, m.elem, poly_map);
        }
    case Dynamic_Array_Type:
        if n, ok := call_node.derived.(Dynamic_Array_Type); ok {
            resolve_poly_spec(ast_context, n.elem, m.elem, poly_map);
        }
    case Struct_Type:
        if n, ok := call_node.derived.(Struct_Type); ok {
            resolve_poly_spec(ast_context, n.poly_params, m.poly_params, poly_map);
            resolve_poly_spec(ast_context, n.align, m.align, poly_map);
            resolve_poly_spec(ast_context, n.fields, m.fields, poly_map);
        }
    case Field:
        if n, ok := call_node.derived.(Field); ok {
            resolve_poly_spec(ast_context, n.names, m.names, poly_map);
            resolve_poly_spec(ast_context, n.type, m.type, poly_map);
            resolve_poly_spec(ast_context, n.default_value, m.default_value, poly_map);
        }
	case Field_List:
        if n, ok := call_node.derived.(Field_List); ok {
            resolve_poly_spec(ast_context, n.list, m.list, poly_map);
        }
    case Field_Value:
        if n, ok := call_node.derived.(Field_Value); ok {
            resolve_poly_spec(ast_context, n.field, m.field, poly_map);
            resolve_poly_spec(ast_context, n.value, m.value, poly_map);
        }
    case Union_Type:
        if n, ok := call_node.derived.(Union_Type); ok {
            resolve_poly_spec(ast_context, n.poly_params, m.poly_params, poly_map);
            resolve_poly_spec(ast_context, n.align, m.align, poly_map);
            resolve_poly_spec(ast_context, n.variants, m.variants, poly_map);
        }
    case Enum_Type:
        if n, ok := call_node.derived.(Enum_Type); ok {
            resolve_poly_spec(ast_context, n.base_type, m.base_type, poly_map);
            resolve_poly_spec(ast_context, n.fields, m.fields, poly_map);
        }
    case Bit_Field_Type:
        if n, ok := call_node.derived.(Bit_Field_Type); ok {
            resolve_poly_spec(ast_context, n.fields, m.fields, poly_map);
        }
    case Bit_Set_Type:
        if n, ok := call_node.derived.(Bit_Set_Type); ok {
            resolve_poly_spec(ast_context, n.elem, m.elem, poly_map);
            resolve_poly_spec(ast_context, n.underlying, m.underlying, poly_map);
        }
    case Map_Type:
        if n, ok := call_node.derived.(Map_Type); ok {
            resolve_poly_spec(ast_context, n.key, m.key, poly_map);
            resolve_poly_spec(ast_context, n.value, m.value, poly_map);
        }
    case Call_Expr:
        if n, ok := call_node.derived.(Call_Expr); ok {
            resolve_poly_spec(ast_context, n.expr, m.expr, poly_map);
            resolve_poly_spec(ast_context, n.args, m.args, poly_map);
        }
    case Typeid_Type:
        if n, ok := call_node.derived.(Typeid_Type); ok {
            resolve_poly_spec(ast_context, n.specialization, m.specialization, poly_map);
        }
    case:
        log.error("Unhandled poly node kind: %T", m);
    }

}

resolve_generic_function :: proc(ast_context: ^AstContext, proc_lit: ast.Proc_Lit) -> (index.Symbol, bool) {

    using ast;

    if proc_lit.type.params == nil {
        return index.Symbol {}, false;
    }

    if proc_lit.type.results == nil {
        return index.Symbol {}, false;
    }

    if ast_context.call == nil {
        return index.Symbol {}, false;
    }

    call_expr := ast_context.call.derived.(Call_Expr);
    poly_map := make(map[string]^Expr, 0, context.temp_allocator);
    i := 0;


    for param in proc_lit.type.params.list {

        for name in param.names {

            if poly, ok := name.derived.(Poly_Type); ok {
                poly_map[poly.type.name] = call_expr.args[i];
            }

            if poly, ok := param.type.derived.(Poly_Type); ok {

                if arg_eval, ok := resolve_type_expression(ast_context, call_expr.args[i], false); ok {

                    if value, ok := arg_eval.value.(index.SymbolGenericValue); ok {
                        resolve_poly_spec_node(ast_context, value.expr, poly.specialization, &poly_map);
                    }

                }
            }

            i += 1;
        }

    }

    ident, ok := call_expr.expr.derived.(Ident);

    if !ok {
        return index.Symbol {}, false;
    }

    location_symbol: index.Symbol;
    location_symbol, ok = resolve_location_identifier(ast_context, ident);

    symbol := index.Symbol {
       range = location_symbol.range,
       type = .Function,
       name = ident.name,
    };

    symbol.signature = strings.concatenate( {"(", string(ast_context.file.src[proc_lit.type.params.pos.offset:proc_lit.type.params.end.offset]), ")"}, context.temp_allocator);

    return_types := make([dynamic]  ^ast.Field, context.temp_allocator);

    for result in proc_lit.type.results.list {

        if ident, ok := result.type.derived.(Ident); ok {
            field := cast(^Field)index.clone_node(result, context.temp_allocator);

            if m := &poly_map[ident.name]; m != nil {
                field.type = poly_map[ident.name];
                append(&return_types, field);
            }

            else{
                return index.Symbol {}, false;
            }

        }

    }

    symbol.value = index.SymbolProcedureValue {
        return_types = return_types[:],
    };

    //log.info(poly_map);

    return symbol, true;
}


/*
    Figure out which function the call expression is using out of the list from proc group
 */
resolve_function_overload :: proc(ast_context: ^AstContext, group: ast.Proc_Group) ->  (index.Symbol, bool) {

    using ast;

    if ast_context.call == nil {
        return index.Symbol {}, false;
    }

    call_expr := ast_context.call.derived.(Call_Expr);

    for arg_expr in group.args {

        next_fn: if f, ok := resolve_type_expression(ast_context, arg_expr, false); ok {

            if procedure, ok := f.value.(index.SymbolProcedureValue); ok {

                if len(procedure.arg_types) != len(call_expr.args) {
                    continue;
                }

                for proc_args, i in procedure.arg_types {

                    if eval_call_expr, ok := resolve_type_expression(ast_context, call_expr.args[i], false); ok {

                        #partial switch v in eval_call_expr.value {
                        case index.SymbolProcedureValue:
                        case index.SymbolGenericValue:
                            if !common.node_equal(proc_args.type, v.expr) {
                                break next_fn;
                            }
                        case index.SymbolStructValue:
                        }

                    }

                    else {
                        return index.Symbol {}, false;
                    }



                }

                return f, true;
            }

        }

    }


    return index.Symbol {}, false;
}

resolve_basic_lit :: proc(ast_context: ^AstContext, basic_lit: ast.Basic_Lit) -> (index.Symbol, bool) {

    /*
        This is temporary, since basic lit is untyped, but either way it's going to be an ident representing a keyword.

        Could perhaps name them "$integer", "$float", etc.
     */

    ident := index.new_type(ast.Ident, basic_lit.pos, basic_lit.end, context.temp_allocator);

    symbol := index.Symbol {
        type = .Keyword,
    };

    if v, ok := strconv.parse_bool(basic_lit.tok.text); ok {
        ident.name = bool_lit;
    }

    else if v, ok := strconv.parse_int(basic_lit.tok.text); ok {
        ident.name = int_lit;
    }

    else {
        ident.name = string_lit;
    }

    symbol.value = index.SymbolGenericValue {
        expr = ident,
    };

    return symbol, true;
}

resolve_type_expression :: proc(ast_context: ^AstContext, node: ^ast.Expr, expect_identifier := true) -> (index.Symbol, bool) {

    using ast;

    switch v in node.derived {
    case Ident:
        return resolve_type_identifier(ast_context, v, expect_identifier);
    case Basic_Lit:
        return resolve_basic_lit(ast_context, v);
    case Index_Expr:
        indexed, ok := resolve_type_expression(ast_context, v.expr, false);

        if generic, ok := indexed.value.(index.SymbolGenericValue); ok {

            switch c in generic.expr.derived {
            case Array_Type:
                return resolve_type_expression(ast_context, c.elem, false);

            }

        }

        return index.Symbol {}, false;
    case Call_Expr:
        ast_context.call = node;
        return resolve_type_expression(ast_context, v.expr, false);
    case Selector_Expr:

        if selector, ok := resolve_type_expression(ast_context, v.expr); ok {

            ast_context.use_locals = false;

            #partial switch s in selector.value {
            case index.SymbolStructValue:

                if selector.uri != "" {
                    ast_context.current_package = selector.scope;
                }

                for name, i in s.names {
                    if v.field != nil && strings.compare(name, v.field.name) == 0 {
                        return resolve_type_expression(ast_context, s.types[i], false);
                    }
                }
            case index.SymbolPackageValue:

                ast_context.current_package = selector.scope;

                if v.field != nil {
                    return index.lookup(v.field.name, selector.scope);
                }

                else {
                    log.error("No field");
                    return index.Symbol {}, false;
                }
            case index.SymbolGenericValue:

                /*
                    Slighty awkward, but you could have a pointer to struct, so have to check, i don't want to remove the pointer info by storing into the struct symbol value,
                    since it can be used for signature infering.
                */

                if ptr, ok := s.expr.derived.(Pointer_Type); ok {

                    log.info(ptr);

                    if symbol, ok := resolve_type_expression(ast_context, ptr.elem, false); ok {

                        #partial switch s2 in symbol.value {
                        case index.SymbolStructValue:

                            if selector.uri != "" {
                                ast_context.current_package = symbol.scope;
                            }

                            for name, i in s2.names {
                                if v.field != nil && strings.compare(name, v.field.name) == 0 {
                                    return resolve_type_expression(ast_context, s2.types[i], false);
                                }
                            }

                        }
                    }

                }

            }

        }

        else {
            return index.Symbol {}, false;
        }
    case:
        log.debugf("default node kind, resolve_type_expression: %T", v);
        return make_symbol_generic_from_ast(ast_context, node), true;
    }

    return index.Symbol {}, false;

}


/*
    Function recusively goes through the identifier until it hits a struct, enum, procedure literals, since you can
    have chained variable declarations. ie. a := foo { test =  2}; b := a; c := b;
 */
resolve_type_identifier :: proc(ast_context: ^AstContext, node: ast.Ident, expect_identifier := false) -> (index.Symbol, bool) {

    using ast;

    //note(Daniel, if global and local ends up being 100% same just make a function that takes the map)
    if local, ok := ast_context.locals[node.name]; ast_context.use_locals && ok {

        switch v in local.derived {
        case Ident:
            return resolve_type_identifier(ast_context, v);
        case Struct_Type:
            return make_symbol_struct_from_ast(ast_context, v), !expect_identifier;
        case Proc_Lit:
            if !v.type.generic {
                return make_symbol_procedure_from_ast(ast_context, v, node.name), !expect_identifier;
            }
            else {
                return resolve_generic_function(ast_context, v);
            }
        case Proc_Group:
            return resolve_function_overload(ast_context, v);
        case Selector_Expr:

            if ident, ok := v.expr.derived.(Ident); ok {

                if selector, ok := resolve_type_identifier(ast_context, ident); ok {

                    if value, ok := selector.value.(index.SymbolPackageValue); ok {
                        return index.lookup(v.field.name, selector.scope);
                    }

                }

            }

            return index.Symbol {}, false;
        case Array_Type:
            return make_symbol_generic_from_ast(ast_context, local), true;
        case Index_Expr:
            return resolve_type_expression(ast_context, local, false);
        case:
            log.errorf("default type node kind: %T", v);
            return make_symbol_generic_from_ast(ast_context, local), true;
        }
    }

    else if global, ok := ast_context.globals[node.name]; ast_context.use_globals && ok {

        switch v in global.derived {
        case Ident:
            return resolve_type_identifier(ast_context, v);
        case Struct_Type:
            return make_symbol_struct_from_ast(ast_context, v), !expect_identifier;
        case Proc_Lit:
            if !v.type.generic {
                return make_symbol_procedure_from_ast(ast_context, v, node.name), !expect_identifier;
            }
            else {
                return resolve_generic_function(ast_context, v);
            }
        case Proc_Group:
            return resolve_function_overload(ast_context, v);
        case Selector_Expr:
            if ident, ok := v.expr.derived.(Ident); ok {

                if selector, ok := resolve_type_identifier(ast_context, ident); ok {

                    if value, ok := selector.value.(index.SymbolPackageValue); ok {
                        return index.lookup(v.field.name, selector.scope);
                    }

                }

            }

            return index.Symbol {}, false;
        case Array_Type:
            return make_symbol_generic_from_ast(ast_context, global), true;
        case Index_Expr:
            return resolve_type_expression(ast_context, global, false);
        case:
            log.errorf("default type node kind: %T", v);
            return make_symbol_generic_from_ast(ast_context, global), true;
        }

    }

    //keywords
    else if node.name == "int" || node.name == "string"
        || node.name == "u64" || node.name == "f32"
        || node.name == "i64" || node.name == "i32"
        || node.name == "bool" || node.name == "rawptr"
        || node.name == "any" {

        symbol := index.Symbol {
            type = .Keyword,
        };

        ident := index.new_type(Ident, node.pos, node.end, context.temp_allocator);
        ident.name = node.name;

        symbol.value = index.SymbolGenericValue {
            expr = ident,
        };

        return symbol, true;
    }

    //imports - probably have this higher to check imports befure everything else
    else {

        //right now we replace the package ident with the absolute directory name, so it should have '/' which is not a valid ident character
        if strings.contains(node.name, "/") {

            symbol := index.Symbol {
                    type = .Package,
                    scope = node.name,
                    value = index.SymbolPackageValue {
                    }
                };

            return symbol, true;

        }

        //part of the ast so we check the imports of the document
        else {

            for imp in ast_context.imports {

                if strings.compare(imp.base, node.name) == 0 {

                    symbol := index.Symbol {
                        type = .Package,
                        scope = imp.name,
                        value = index.SymbolPackageValue {
                        }
                    };

                    return symbol, true;
                }

            }

        }

        //last option is to check the index

        return index.lookup(node.name, ast_context.current_package);


        //TODO(daniel, index can be used on identifiers if using is in the function scope)
    }

    return index.Symbol {}, false;
}

resolve_location_identifier :: proc(ast_context: ^AstContext, node: ast.Ident) -> (index.Symbol, bool) {

    symbol: index.Symbol;

    if local, ok := ast_context.locals[node.name]; ok {
        symbol.range = common.get_token_range(local, ast_context.file.src);
        return symbol, true;
    }

    else if global, ok := ast_context.globals[node.name]; ok {
        symbol.range = common.get_token_range(global, ast_context.file.src);
        return symbol, true;
    }

    return symbol, false;
}

make_symbol_procedure_from_ast :: proc(ast_context: ^AstContext, v: ast.Proc_Lit, name: string) -> index.Symbol {

    symbol := index.Symbol {
        range = common.get_token_range(v, ast_context.file.src),
        type = .Function,
    };

    symbol.name = name;
    symbol.signature = strings.concatenate( {"(", string(ast_context.file.src[v.type.params.pos.offset:v.type.params.end.offset]), ")"}, context.temp_allocator);

    return_types := make([dynamic] ^ast.Field, context.temp_allocator);
    arg_types := make([dynamic] ^ast.Field, context.temp_allocator);

    if v.type.results != nil {

        for ret in v.type.results.list {
            append(&return_types, ret);
        }

    }

    if v.type.params != nil {

        for param in v.type.params.list {
            append(&arg_types, param);
        }

    }

    symbol.value = index.SymbolProcedureValue {
        return_types = return_types[:],
        arg_types = arg_types[:],
    };

    return symbol;
}

make_symbol_generic_from_ast :: proc(ast_context: ^AstContext, expr: ^ast.Expr) -> index.Symbol {

    symbol := index.Symbol {
        range = common.get_token_range(expr, ast_context.file.src),
        type = .Variable,
    };

    symbol.value = index.SymbolGenericValue {
        expr = expr,
    };

    return symbol;
}


make_symbol_struct_from_ast :: proc(ast_context: ^AstContext, v: ast.Struct_Type) -> index.Symbol {

    symbol := index.Symbol {
        range = common.get_token_range(v, ast_context.file.src),
        type = .Struct,
    };

    names := make([dynamic] string, context.temp_allocator);
    types := make([dynamic] ^ast.Expr, context.temp_allocator);

    for field in v.fields.list {

        for n in field.names {
            identifier := n.derived.(ast.Ident);
            append(&names, identifier.name);
            append(&types, index.clone_type(field.type, context.temp_allocator));
        }

    }

    symbol.value = index.SymbolStructValue {
        names = names[:],
        types = types[:],
    };

    return symbol;
}

get_globals :: proc(file: ast.File, ast_context: ^AstContext) {

    for decl in file.decls {

        if value_decl, ok := decl.derived.(ast.Value_Decl); ok {

            for name, i in value_decl.names {

                str := common.get_ast_node_string(name, file.src);



                if value_decl.type != nil {
                    ast_context.globals[str] = value_decl.type;
                    //log.infof("name: %v, %v", str, value_decl.type.derived);
                }

                else {
                    //log.infof("name: %v, %v", str, value_decl.values[i].derived);
                    ast_context.globals[str] = value_decl.values[i];
                }

            }

        }
    }
}

get_locals_value_decl :: proc(file: ast.File, value_decl: ast.Value_Decl, ast_context: ^AstContext) {

    using ast;

    if value_decl.type != nil {
        str := common.get_ast_node_string(value_decl.names[0], file.src);
        ast_context.locals[str] = value_decl.type;
        return;
    }

    ast_context.use_locals = true;
    ast_context.use_globals = true;

    results := make([dynamic]^Expr, context.temp_allocator);

    for value in value_decl.values {

        switch v in value.derived {
        case Call_Expr:

            ast_context.call = value;

            if symbol, ok := resolve_type_expression(ast_context, v.expr, false); ok {

                if procedure, ok := symbol.value.(index.SymbolProcedureValue); ok {

                    for ret in procedure.return_types {
                        append(&results, ret.type);
                    }

                }

            }

        case Comp_Lit:
            append(&results, v.type);
        case:
            log.debugf("default node get_locals_value_decl %v", v);
            append(&results, value);
        }

    }

    if len(value_decl.names) == len(results) {

        for name, i in value_decl.names {
            str := common.get_ast_node_string(name, file.src);
            ast_context.locals[str] = results[i];
        }

    }

}

get_locals_stmt :: proc(file: ast.File, stmt: ^ast.Stmt, ast_context: ^AstContext) {

    using ast;

    switch v in stmt.derived {
    case Value_Decl:
        get_locals_value_decl(file, v, ast_context);
    case Type_Switch_Stmt:
        get_locals_type_switch_stmt(file, v, ast_context);
    case:
        log.debugf("default node local stmt %v", v);
    }

}

get_locals_type_switch_stmt :: proc(file: ast.File, stmt: ast.Type_Switch_Stmt, ast_context: ^AstContext) {

}

get_locals :: proc(file: ast.File, function: ^ast.Node, ast_context: ^AstContext) {

    proc_lit, ok := function.derived.(ast.Proc_Lit);

    if !ok || proc_lit.body == nil {
        return;
    }

    if proc_lit.type != nil && proc_lit.type.params != nil {

        for arg in proc_lit.type.params.list {

            for name in arg.names {
                if arg.type != nil {
                    str := common.get_ast_node_string(name, file.src);
                    ast_context.locals[str] = arg.type;
                }
            }

        }

    }

    block: ast.Block_Stmt;
    block, ok = proc_lit.body.derived.(ast.Block_Stmt);

    if !ok {
        return;
    }

    for stmt in block.stmts {
        get_locals_stmt(file, stmt, ast_context);
    }

}

get_definition_location :: proc(document: ^Document, position: common.Position) -> (common.Location, bool) {

    location: common.Location;


    ast_context := make_ast_context(document.ast, document.imports, document.package_name);

    uri: string;

    position_context, ok := get_document_position_context(document, position, .Definition);

    if !ok {
        log.error("Failed to get position context");
        return location, false;
    }

    get_globals(document.ast, &ast_context);

    if position_context.function != nil {
        get_locals(document.ast, position_context.function, &ast_context);
    }

    if position_context.identifier != nil {

        if resolved, ok := resolve_location_identifier(&ast_context, position_context.identifier.derived.(ast.Ident)); ok {
            location.range = resolved.range;
            location.uri = resolved.uri;
        }

        else {
            return location, false;
        }

    }

    else if position_context.selector != nil && position_context.field != nil {

        selector: index.Symbol;

        selector, ok = resolve_type_expression(&ast_context, position_context.selector);

        if !ok {
            return location, false;
        }

        field: string;

        switch v in position_context.field.derived {
        case ast.Ident:
            field = v.name;
        case:
            return location, false;
        }

        #partial switch v in selector.value {
        case index.SymbolStructValue:
            for name, i in v.names {
                if strings.compare(name, field) == 0 {
                    location.range = common.get_token_range(v.types[i]^, document.ast.src);
                }
            }
        case index.SymbolPackageValue:
            if symbol, ok := index.lookup(field, selector.scope); ok {
                location.range = symbol.range;
                uri = symbol.uri;
            }
            else {
                return location, false;
            }
        }

        if !ok {
            return location, false;
        }

    }

    else {
        return location, false;
    }

    //if the symbol is generated by the ast we don't set the uri.
    if uri == "" {
        location.uri = document.uri.uri;
    }

    else {
        location.uri = uri;
    }

    return location, true;
}

get_completion_list :: proc(document: ^Document, position: common.Position) -> (CompletionList, bool) {

    list: CompletionList;

    ast_context := make_ast_context(document.ast, document.imports, document.package_name);

    position_context, ok := get_document_position_context(document, position, .Completion);

    get_globals(document.ast, &ast_context);

    if position_context.function != nil {
        get_locals(document.ast, position_context.function, &ast_context);
    }

    items := make([dynamic] CompletionItem, context.temp_allocator);


    if position_context.selector != nil {

        symbols := make([dynamic] index.Symbol, context.temp_allocator);

        selector: index.Symbol;

        selector, ok = resolve_type_expression(&ast_context, position_context.selector);

        if !ok {
            log.error("Failed to resolve type selector");
            return list, true;
        }


        if selector.uri != "" {
            ast_context.current_package = selector.scope;
        }

        field: string;

        if position_context.field != nil {

            switch v in position_context.field.derived {
            case ast.Ident:
                field = v.name;
            }

        }

        #partial switch v in selector.value {
        case index.SymbolStructValue:

            list.isIncomplete = false;

            for name, i in v.names {

                if symbol, ok := resolve_type_expression(&ast_context, v.types[i], false); ok {
                    symbol.name = name;
                    symbol.type = .Field;
                    append(&symbols, symbol);
                }

                else {
                    log.errorf("Failed to resolve field: %v", name);
                    return list, true;
                }

            }


        case index.SymbolPackageValue:

            list.isIncomplete = true;

            if field != "" {

                if searched, ok := index.fuzzy_search(selector.name, {selector.scope}); ok {

                    for search in searched {
                        append(&symbols, search);
                    }

                }

                else {
                    log.errorf("Failed to fuzzy search, field: %v, package: %v", field, selector.scope);
                    return list, true;
                }

            }
        case index.SymbolGenericValue:

            list.isIncomplete = false;

            if ptr, ok := v.expr.derived.(ast.Pointer_Type); ok {

                log.info(ptr);

                if symbol, ok := resolve_type_expression(&ast_context, ptr.elem, false); ok {

                    #partial switch s in symbol.value {
                    case index.SymbolStructValue:
                        for name, i in s.names {

                            if symbol, ok := resolve_type_expression(&ast_context, s.types[i], false); ok {
                                symbol.name = name;
                                symbol.type = .Field;
                                append(&symbols, symbol);
                            }

                            else {
                                log.errorf("Failed to resolve field: %v", name);
                                return list, true;
                            }
                        }
                    }
                }

            }

        }

        for symbol, i in symbols {
            item := CompletionItem {
                label = symbol.name,
                kind = cast(CompletionItemKind) symbol.type,
            };

            append(&items, item);
        }

        //if there is no field we had to recover from bad expr and create a node (remove when parser can accept temp_allocator)
        if position_context.field == nil {
            common.free_ast(position_context.selector);
        }

        list.items = items[:];
    }

    else {

        /*
            Just show the local and global symbols of the document

            TODO(Add fuzzy matching)
        */

        for k, v in ast_context.locals {

            item := CompletionItem {
                label = k,
            };


            append(&items, item);
        }

        for k, v in ast_context.globals {

            item := CompletionItem {
                label = k,
            };

            append(&items, item);
        }

        ident := index.new_type(ast.Ident, tokenizer.Pos {}, tokenizer.Pos {}, context.temp_allocator);

        for item, i in items {

            ident.name = item.label;

            if symbol, ok := resolve_type_identifier(&ast_context, ident^, true); ok {
                items[i].kind = .Variable;
            }

            else if symbol, ok := resolve_type_identifier(&ast_context, ident^, false); ok {
                items[i].kind = cast(CompletionItemKind)symbol.type;
            }


        }

        list.items = items[:];
    }



    return list, true;
}

get_signature_information :: proc(document: ^Document, position: common.Position) -> (SignatureHelp, bool) {

    signature_help: SignatureHelp;

    ast_context := make_ast_context(document.ast, document.imports, document.package_name);

    position_context, ok := get_document_position_context(document, position, .SignatureHelp);

    if !ok {
        return signature_help, false;
    }

    if position_context.call == nil {
        return signature_help, false;
    }

    get_globals(document.ast, &ast_context);

    if position_context.function != nil {
        get_locals(document.ast, position_context.function, &ast_context);
    }

    call: index.Symbol;
    call, ok = resolve_type_expression(&ast_context, position_context.call);

    signature_information := make([] SignatureInformation, 1, context.temp_allocator);

    signature_information[0].label = strings.concatenate({call.name, call.signature}, context.temp_allocator);

    signature_help.signatures = signature_information;

    return signature_help, true;
}


/*
    Figure out what exactly is at the given position and whether it is in a function, struct, etc.
*/
get_document_position_context :: proc(document: ^Document, position: common.Position, hint: DocumentPositionContextHint) -> (DocumentPositionContext, bool) {

    position_context: DocumentPositionContext;

    position_context.hint = hint;
    position_context.file = document.ast;

    absolute_position, ok := common.get_absolute_position(position, document.text);

    if !ok {
        log.error("failed to get absolute position");
        return position_context, false;
    }

    position_context.position = absolute_position;

    for decl in document.ast.decls {
        get_document_position(decl, &position_context);
    }

    return position_context, true;
}

get_document_position :: proc{
    get_document_position_array,
    get_document_position_dynamic_array,
    get_document_position_node,
};

get_document_position_array :: proc(array: $A/[]^$T, position_context: ^DocumentPositionContext) {

    for elem, i in array {
        get_document_position(elem, position_context);
    }

}

get_document_position_dynamic_array :: proc(array: $A/[dynamic]^$T, position_context: ^DocumentPositionContext) {

    for elem, i in array {
        get_document_position(elem, position_context);
    }

}

position_in_node :: proc(node: ^ast.Node, position: common.AbsolutePosition) -> bool {
    return node != nil && node.pos.offset <= position && position <= node.end.offset;
}

get_document_position_node :: proc(node: ^ast.Node, position_context: ^DocumentPositionContext) {

    using ast;

    if node == nil {
        return;
    }

    if !position_in_node(node, position_context.position) {
        return;
    }

    switch n in node.derived {
    case Bad_Expr:
        if position_context.hint == .Completion && position_context.file.src[max(0, node.end.offset-1)] == '.' {


            str := position_context.file.src[node.pos.offset:max(0, node.end.offset-1)];

            p := parser.default_parser();

            tokenizer.init(&p.tok, str, position_context.file.fullpath);

            parser.advance_token(&p);

            //do we still have recursive dots?
            if strings.contains(string(str), ".") {
                e := parser.parse_expr(&p, true);
                position_context.selector = e;
            }

            else {
                e := parser.parse_ident(&p);
                position_context.selector = e;
            }


        }

    case Ident:
        position_context.identifier = node;
        return;
    case Implicit:
    case Undef:
    case Basic_Lit:
    case Ellipsis:
        get_document_position(n.expr, position_context);
    case Proc_Lit:
        get_document_position(n.type, position_context);

        if position_in_node(n.body, position_context.position) {
            position_context.function = node;
            get_document_position(n.body, position_context);
        }
    case Comp_Lit:
        get_document_position(n.type, position_context);
        get_document_position(n.elems, position_context);
    case Tag_Expr:
        get_document_position(n.expr, position_context);
    case Unary_Expr:
        get_document_position(n.expr, position_context);
    case Binary_Expr:
        get_document_position(n.left, position_context);
        get_document_position(n.right, position_context);
    case Paren_Expr:
        get_document_position(n.expr, position_context);
    case Call_Expr:
        if position_context.hint == .SignatureHelp  {
            position_context.call = cast(^Expr)node;
        }
        get_document_position(n.expr, position_context);
        get_document_position(n.args, position_context);
    case Selector_Expr:
        if position_context.hint == .Completion || position_context.hint == .Definition {
            position_context.selector = n.expr;
            position_context.field = n.field;
        }
        else {
            get_document_position(n.expr, position_context);
            get_document_position(n.field, position_context);
        }
    case Index_Expr:
        get_document_position(n.expr, position_context);
        get_document_position(n.index, position_context);
    case Deref_Expr:
        get_document_position(n.expr, position_context);
    case Slice_Expr:
        get_document_position(n.expr, position_context);
        get_document_position(n.low, position_context);
        get_document_position(n.high, position_context);
    case Field_Value:
        get_document_position(n.field, position_context);
        get_document_position(n.value, position_context);
    case Ternary_Expr:
        get_document_position(n.cond, position_context);
        get_document_position(n.x, position_context);
        get_document_position(n.y, position_context);
    case Ternary_If_Expr:
        get_document_position(n.x, position_context);
        get_document_position(n.cond, position_context);
        get_document_position(n.y, position_context);
    case Ternary_When_Expr:
        get_document_position(n.x, position_context);
        get_document_position(n.cond, position_context);
        get_document_position(n.y, position_context);
    case Type_Assertion:
        get_document_position(n.expr, position_context);
        get_document_position(n.type, position_context);
    case Type_Cast:
        get_document_position(n.type, position_context);
        get_document_position(n.expr, position_context);
    case Auto_Cast:
        get_document_position(n.expr, position_context);
    case Bad_Stmt:
    case Empty_Stmt:
    case Expr_Stmt:
        get_document_position(n.expr, position_context);
    case Tag_Stmt:
        r := cast(^Expr_Stmt)node;
        get_document_position(r.expr, position_context);
    case Assign_Stmt:
        get_document_position(n.lhs, position_context);
        get_document_position(n.rhs, position_context);
    case Block_Stmt:
        get_document_position(n.label, position_context);
        get_document_position(n.stmts, position_context);
    case If_Stmt:
        get_document_position(n.label, position_context);
        get_document_position(n.init, position_context);
        get_document_position(n.cond, position_context);
        get_document_position(n.body, position_context);
        get_document_position(n.else_stmt, position_context);
    case When_Stmt:
        get_document_position(n.cond, position_context);
        get_document_position(n.body, position_context);
        get_document_position(n.else_stmt, position_context);
    case Return_Stmt:
        get_document_position(n.results, position_context);
    case Defer_Stmt:
        get_document_position(n.stmt, position_context);
    case For_Stmt:
        get_document_position(n.label, position_context);
        get_document_position(n.init, position_context);
        get_document_position(n.cond, position_context);
        get_document_position(n.post, position_context);
        get_document_position(n.body, position_context);
    case Range_Stmt:
        get_document_position(n.label, position_context);
        get_document_position(n.val0, position_context);
        get_document_position(n.val1, position_context);
        get_document_position(n.expr, position_context);
        get_document_position(n.body, position_context);
    case Case_Clause:
        get_document_position(n.list, position_context);
        get_document_position(n.body, position_context);
    case Switch_Stmt:
        get_document_position(n.label, position_context);
        get_document_position(n.init, position_context);
        get_document_position(n.cond, position_context);
        get_document_position(n.body, position_context);
    case Type_Switch_Stmt:
        get_document_position(n.label, position_context);
        get_document_position(n.tag, position_context);
        get_document_position(n.expr, position_context);
        get_document_position(n.body, position_context);
    case Branch_Stmt:
        get_document_position(n.label, position_context);
    case Using_Stmt:
        get_document_position(n.list, position_context);
    case Bad_Decl:
    case Value_Decl:
        get_document_position(n.attributes, position_context);
        get_document_position(n.names, position_context);
        get_document_position(n.type, position_context);
        get_document_position(n.values, position_context);
    case Package_Decl:
    case Import_Decl:
    case Foreign_Block_Decl:
        get_document_position(n.attributes, position_context);
        get_document_position(n.foreign_library, position_context);
        get_document_position(n.body, position_context);
    case Foreign_Import_Decl:
        get_document_position(n.name, position_context);
    case Proc_Group:
        get_document_position(n.args, position_context);
    case Attribute:
        get_document_position(n.elems, position_context);
    case Field:
        get_document_position(n.names, position_context);
        get_document_position(n.type, position_context);
        get_document_position(n.default_value, position_context);
    case Field_List:
        get_document_position(n.list, position_context);
    case Typeid_Type:
        get_document_position(n.specialization, position_context);
    case Helper_Type:
        get_document_position(n.type, position_context);
    case Distinct_Type:
        get_document_position(n.type, position_context);
    case Opaque_Type:
        get_document_position(n.type, position_context);
    case Poly_Type:
        get_document_position(n.type, position_context);
        get_document_position(n.specialization, position_context);
    case Proc_Type:
        get_document_position(n.params, position_context);
        get_document_position(n.results, position_context);
    case Pointer_Type:
        get_document_position(n.elem, position_context);
    case Array_Type:
        get_document_position(n.len, position_context);
        get_document_position(n.elem, position_context);
    case Dynamic_Array_Type:
        get_document_position(n.elem, position_context);
    case Struct_Type:
        get_document_position(n.poly_params, position_context);
        get_document_position(n.align, position_context);
        get_document_position(n.fields, position_context);
    case Union_Type:
        get_document_position(n.poly_params, position_context);
        get_document_position(n.align, position_context);
        get_document_position(n.variants, position_context);
    case Enum_Type:
        get_document_position(n.base_type, position_context);
        get_document_position(n.fields, position_context);
    case Bit_Field_Type:
        get_document_position(n.fields, position_context);
    case Bit_Set_Type:
        get_document_position(n.elem, position_context);
        get_document_position(n.underlying, position_context);
    case Map_Type:
        get_document_position(n.key, position_context);
        get_document_position(n.value, position_context);
    case:
        log.errorf("Unhandled node kind: %T", n);
    }

}