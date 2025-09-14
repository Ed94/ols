package server

import "core:fmt"
import "core:log"
import "core:mem"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:path/filepath"
import path "core:path/slashpath"
import "core:slice"
import "core:sort"
import "core:strconv"
import "core:strings"

import "src:common"

get_all_package_file_locations :: proc(
	document: ^Document,
	import_decl: ^ast.Import_Decl,
	locations: ^[dynamic]common.Location,
) -> bool {
	import_path := ""

	for imp in document.imports {
		if imp.original == import_decl.fullpath {
			import_path = imp.name
		}
	}

	matches, err := filepath.glob(fmt.tprintf("%v/*.odin", import_path), context.temp_allocator)

	for match in matches {
		log.errorf("get_all_package_file_locations match: %v", match)
		uri := common.create_uri(match, context.temp_allocator)
		location := common.Location{
			uri = uri.uri,
		}
		append(locations, location)
	}

	return true
}

get_definition_location :: proc(document: ^Document, position: common.Position) -> ([]common.Location, bool) {
	log.errorf("[DEBUG] get_definition_location called for document: %s at position: %d:%d", document.uri.uri, position.line, position.character)
	
	locations := make([dynamic]common.Location, context.temp_allocator)
	location: common.Location
	uri: string
	position_context, ok := get_document_position_context(document, position, .Definition)

	log.errorf("[DEBUG] get_document_position_context returned ok=%v", ok)
	if !ok {
		log.errorf("[DEBUG] Failed to get position context - early return")
		return {}, false
	}

	log.errorf("[DEBUG] Position context obtained successfully")

	ast_context := make_ast_context(
		document.ast,
		document.imports,
		document.package_name,
		document.uri.uri,
		document.fullpath,
	)

	ast_context.position_hint = position_context.hint

	get_globals(document.ast, &ast_context)

	if position_context.function != nil {
		log.errorf("[DEBUG] Position Context: function")
		get_locals(document.ast, position_context.function, &ast_context, &position_context)
	}

	// Log all position context state
	log.errorf("[DEBUG] Position Context Debug:")
	log.errorf("[DEBUG]   import_stmt: %v", position_context.import_stmt != nil)
	log.errorf("[DEBUG]   selector_expr: %v", position_context.selector_expr != nil)
	log.errorf("[DEBUG]   identifier: %v", position_context.identifier != nil)
	log.errorf("[DEBUG]   field_value: %v", position_context.field_value != nil)
	log.errorf("[DEBUG]   implicit_selector_expr: %v", position_context.implicit_selector_expr != nil)
	log.errorf("[DEBUG]   comp_lit: %v", position_context.comp_lit != nil)
	log.errorf("[DEBUG]   hint: %v", position_context.hint)
	
	if position_context.selector_expr != nil {
		if selector, ok := position_context.selector_expr.derived.(^ast.Selector_Expr); ok {
			log.errorf("[DEBUG]   Selector details:")
			if field_ident, ok := selector.field.derived.(^ast.Ident); ok {
				log.errorf("[DEBUG]     Field: %s", field_ident.name)
			}
			if position_context.selector != nil {
				log.errorf("[DEBUG]     position_context.selector is set")
			} else {
				log.errorf("[DEBUG]     position_context.selector is nil!")
			}
			if position_context.field != nil {
				log.errorf("[DEBUG]     position_context.field is set")
			} else {
				log.errorf("[DEBUG]     position_context.field is nil!")
			}
		}
	}
	
	if position_context.import_stmt != nil {
		log.errorf("[DEBUG] Position Context: import_stmt")
		if get_all_package_file_locations(document, position_context.import_stmt, &locations) {
			return locations[:], true
		}
	} else if position_context.selector_expr != nil {
		log.errorf("[DEBUG] Position Context: selector_expr")
		
		// Log the selector expression details
		if selector, ok := position_context.selector_expr.derived.(^ast.Selector_Expr); ok {
			if field_ident, ok := selector.field.derived.(^ast.Ident); ok {
				log.errorf("[DEBUG]   Field: %s", field_ident.name)
			}
			if base_ident, ok := selector.expr.derived.(^ast.Ident); ok {
				log.errorf("[DEBUG]   Base (Ident): %s", base_ident.name)
			} else if nested_selector, ok := selector.expr.derived.(^ast.Selector_Expr); ok {
				log.errorf("[DEBUG]   Base is nested selector")
				if nested_field, ok := nested_selector.field.derived.(^ast.Ident); ok {
					log.errorf("[DEBUG]     Nested field: %s", nested_field.name)
				}
			}
		}
		//if the base selector is the client wants to go to.
		if position_in_node(position_context.selector, position_context.position) &&
		   position_context.identifier != nil {
			ident := position_context.identifier.derived.(^ast.Ident)
			if resolved, ok := resolve_location_identifier(&ast_context, ident^); ok {
				location.range = resolved.range

				if resolved.uri == "" {
					location.uri = document.uri.uri
				} else {
					location.uri = resolved.uri
				}

				append(&locations, location)

				return locations[:], true
			} else {
				return {}, false
			}
		}

		log.errorf("[DEBUG] About to call resolve_location_selector")
		if resolved, ok := resolve_location_selector(&ast_context, position_context.selector_expr); ok {
			location.range = resolved.range
			uri = resolved.uri
			log.errorf("[DEBUG] Successfully resolved selector - URI: %s, Range: %v", resolved.uri, resolved.range)
		} else {
			log.errorf("[DEBUG] Failed to resolve_location_selector")
			return {}, false
		}
	} else if position_context.field_value != nil &&
	   !is_expr_basic_lit(position_context.field_value.field) &&
	   position_in_node(position_context.field_value.field, position_context.position) {
		if position_context.comp_lit != nil {
			log.errorf("[DEBUG] Position Context: field_value + comp_lit")
			log.errorf("[DEBUG] About to call resolve_location_comp_lit_field")
			if resolved, ok := resolve_location_comp_lit_field(&ast_context, &position_context); ok {
				location.range = resolved.range
				uri = resolved.uri
				log.errorf("[DEBUG] Successfully resolved comp_lit_field - URI: %s, Range: %v", resolved.uri, resolved.range)
			} else {
				log.errorf("[DEBUG] Failed to resolve_location_comp_lit_field")
				return {}, false
			}
		} else if position_context.call != nil {
			if resolved, ok := resolve_location_proc_param_name(&ast_context, &position_context); ok {
				location.range = resolved.range
				uri = resolved.uri
			} else {
				return {}, false
			}
		}
	} else if position_context.implicit_selector_expr != nil {
		log.errorf("[DEBUG] Position Context: implicit_selector_expr")
		log.errorf("[DEBUG] About to call resolve_location_implicit_selector")
		if resolved, ok := resolve_location_implicit_selector(
			&ast_context,
			&position_context,
			position_context.implicit_selector_expr,
		); ok {
			location.range = resolved.range
			uri = resolved.uri
			log.errorf("[DEBUG] Successfully resolved implicit_selector - URI: %s, Range: %v", resolved.uri, resolved.range)
		} else {
			log.errorf("[DEBUG] Failed to resolve_location_implicit_selector")
			return {}, false
		}
	} else if position_context.identifier != nil {
		log.errorf("[DEBUG] Position Context: identifier")
		log.errorf("[DEBUG] About to call resolve_location_identifier")
		if resolved, ok := resolve_location_identifier(
			&ast_context,
			position_context.identifier.derived.(^ast.Ident)^,
		); ok {
			if v, ok := resolved.value.(SymbolAggregateValue); ok {
				for symbol in v.symbols {
					append(&locations, common.Location {
						range = symbol.range,
						uri = symbol.uri,
					})
				}
			}
			location.range = resolved.range
			uri = resolved.uri
			log.errorf("[DEBUG] Successfully resolved identifier - URI: %s, Range: %v", resolved.uri, resolved.range)
		} else {
			log.errorf("[DEBUG] Failed to resolve_location_identifier")
			return {}, false
		}
	} else {
		log.errorf("[DEBUG] No matching position context type found - falling through to failure")
		return {}, false
	}

	//if the symbol is generated by the ast we don't set the uri.
	if uri == "" {
		location.uri = document.uri.uri
		log.errorf("[DEBUG] Using document URI (no resolved URI): %s", location.uri)
	} else {
		location.uri = uri
		log.errorf("[DEBUG] Using resolved URI: %s", location.uri)
	}

	log.errorf("[DEBUG] Final location: URI=%s, Range=%v", location.uri, location.range)
	append(&locations, location)

	return locations[:], true
}
