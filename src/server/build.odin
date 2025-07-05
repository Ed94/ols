#+feature dynamic-literals
package server

import "base:runtime"

import "core:fmt"
import "core:log"
import "core:mem"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:path/filepath"
import path "core:path/slashpath"
import "core:strings"
import "core:time"

import "src:common"

platform_os: map[string]bool = {
	"windows" = true,
	"linux"   = true,
	"essence" = true,
	"js"      = true,
	"freebsd" = true,
	"darwin"  = true,
	"wasm32"  = true,
	"openbsd" = true,
	"wasi"    = true,
	"wasm"    = true,
	"haiku"   = true,
	"netbsd"  = true,
	"freebsd" = true,
}


os_enum_to_string: map[runtime.Odin_OS_Type]string = {
	.Windows      = "windows",
	.Darwin       = "darwin",
	.Linux        = "linux",
	.Essence      = "essence",
	.FreeBSD      = "freebsd",
	.WASI         = "wasi",
	.JS           = "js",
	.Freestanding = "freestanding",
	.JS           = "wasm",
	.Haiku        = "haiku",
	.OpenBSD      = "openbsd",
	.NetBSD       = "netbsd",
	.FreeBSD      = "freebsd",
}

@(private = "file")
is_bsd_variant :: proc(name: string) -> bool {
	return(
		common.config.profile.os == os_enum_to_string[.FreeBSD] ||
		common.config.profile.os == os_enum_to_string[.OpenBSD] ||
		common.config.profile.os == os_enum_to_string[.NetBSD] \
	)
}

@(private = "file")
is_unix_variant :: proc(name: string) -> bool {
	return(
		common.config.profile.os == os_enum_to_string[.Linux] ||
		common.config.profile.os == os_enum_to_string[.Darwin] \
	)
}

// TODO(Ed): Review usage of temp allocator here..
// @(private)
get_package_files :: proc(pkg_name: string, allocator := context.allocator) -> (matches: []string, err: os.Error) {
	monolithic_path := path.join({pkg_name, ".ODIN_MONOLITHIC_PACKAGE"}, context.temp_allocator)

	if os.exists(monolithic_path) {
		log.errorf("Processing monolithic package: %s", pkg_name)
		files := make([dynamic]string, 0, 10, allocator)

		walk_proc :: proc(info: os.File_Info, in_err: os.Error, user_data: rawptr) -> (err: os.Error, skip_dir: bool) {
			if in_err != os.General_Error.None {
				// Let filepath.walk handle the error reporting.
				// We return nil to continue walking if possible, but the error will be returned by filepath.walk.
				return nil, false
			}

			if !info.is_dir && filepath.ext(info.name) == ".odin" {
				files_ptr := cast(^[dynamic]string)user_data
				append(files_ptr, strings.clone(info.fullpath, context.temp_allocator))
			}

			return nil, false
		}

		walk_err := filepath.walk(pkg_name, walk_proc, &files)
		if walk_err != nil {
			log.errorf("filepath.walk failed for monolithic package %v: %v", pkg_name, walk_err)
			return nil, .Unknown
		}
		log.errorf("Monolithic package %s contains %d .odin files", pkg_name, len(files))
		return files[:], os.General_Error.None
	}

	match_error : filepath.Match_Error
	matches, match_error = filepath.glob(fmt.tprintf("%v/*.odin", pkg_name), allocator)
	return matches, os.General_Error.None
}

skip_file :: proc(filename: string) -> bool {
	last_underscore_index := strings.last_index(filename, "_")
	last_dot_index := strings.last_index(filename, ".")

	if last_underscore_index + 1 < last_dot_index {
		name_between := filename[last_underscore_index + 1:last_dot_index]

		if name_between == "unix" {
			return !is_unix_variant(name_between)
		}

		if name_between == "bsd" {
			return !is_bsd_variant(name_between)
		}

		if _, ok := platform_os[name_between]; ok {
			return name_between != common.config.profile.os
		}
	}

	return false
}

try_build_package :: proc(pkg_name: string) {
	if pkg, ok := build_cache.loaded_pkgs[pkg_name]; ok {
		return
	}

	monolithic_file_path := path.join({pkg_name, ".ODIN_MONOLITHIC_PACKAGE"}, context.temp_allocator)
	is_monolithic := os.exists(monolithic_file_path)

	when (false) {
	matches: []string
		if is_monolithic {
			files := make([dynamic]string, 0, 10, context.temp_allocator)
			// Recursive walk for monolithic packages
			walk_proc :: proc(info: os.File_Info, in_err: os.Errno, user_data: rawptr) -> (err: os.Error, skip_dir: bool) {
				data := cast(^[dynamic]string)user_data
				if !info.is_dir && filepath.ext(info.name) == ".odin" {
					append(data, strings.clone(info.fullpath, context.temp_allocator))
				}
				return nil, false
			}
			filepath.walk(pkg_name, walk_proc, &files)
			matches = files[:]
		} else {
			err: filepath.Match_Error
			matches, err = filepath.glob(fmt.tprintf("%v/*.odin", pkg_name), context.temp_allocator)
			if err != .None {
				log.errorf("Failed to glob %v for indexing package", pkg_name)
				return
			}
		}
	}

	matches, err := get_package_files(pkg_name, context.temp_allocator)
	if err != os.General_Error.None {
		log.errorf("Failed to get package files for %v", pkg_name)
		return
	}

	arena: runtime.Arena
	result := runtime.arena_init(&arena, mem.Megabyte * 40, runtime.default_allocator())
	defer runtime.arena_destroy(&arena)

	{
		context.allocator = runtime.arena_allocator(&arena)

		for fullpath in matches {
			if skip_file(filepath.base(fullpath)) {
				continue
			}

			data, ok := os.read_entire_file(fullpath, context.allocator)

			if !ok {
				log.errorf("failed to read entire file for indexing %v", fullpath)
				continue
			}

			p := parser.Parser {
				err   = log_error_handler,
				warn  = log_warning_handler,
				flags = {.Optional_Semicolons},
			}

			dir := filepath.base(filepath.dir(fullpath, context.allocator))

			pkg := new(ast.Package)
			pkg.kind = .Normal
			pkg.fullpath = fullpath
			pkg.name = dir

			if dir == "runtime" {
				pkg.kind = .Runtime
			}

			file := ast.File {
				fullpath = fullpath,
				src      = string(data),
				pkg      = pkg,
			}

			ok = parser.parse_file(&p, &file)

			if !ok {
				if !strings.contains(fullpath, "builtin.odin") && !strings.contains(fullpath, "intrinsics.odin") {
					log.errorf("error in parse file for indexing %v", fullpath)
				}
				continue
			}

			uri := common.create_uri(fullpath, context.allocator)

			collect_symbols(&indexer.index.collection, file, uri.uri)

			runtime.arena_free_all(&arena)
		}
	}

	build_cache.loaded_pkgs[strings.clone(pkg_name, indexer.index.collection.allocator)] = PackageCacheInfo {
		timestamp = time.now(),
	}
}

try_build_package_debug :: proc(pkg_name: string) {
	log.errorf("=== try_build_package called for: %v ===", pkg_name)
	
	if pkg, ok := build_cache.loaded_pkgs[pkg_name]; ok {
		log.errorf("Package already loaded: %v (timestamp: %v)", pkg_name, pkg.timestamp)
		return
	}

	log.errorf("Building new package: %v", pkg_name)

	monolithic_file_path := path.join({pkg_name, ".ODIN_MONOLITHIC_PACKAGE"}, context.temp_allocator)
	is_monolithic := os.exists(monolithic_file_path)
	
	if is_monolithic {
		log.errorf("  -> Monolithic package detected")
	} else {
		log.errorf("  -> Regular package")
	}

	matches, err := get_package_files(pkg_name, context.temp_allocator)
	if err != os.General_Error.None {
		log.errorf("Failed to get package files for %v: %v", pkg_name, err)
		return
	}

	log.errorf("  -> Found %d files to index", len(matches))
	
	if len(matches) == 0 {
		log.errorf("  -> No files found for package: %v", pkg_name)
		return
	}

	// Log the files being indexed
	for file, i in matches {
		log.errorf("  -> File %d: %v", i+1, file)
	}

	// Continue with existing build logic...
	arena: runtime.Arena
	result := runtime.arena_init(&arena, mem.Megabyte * 40, runtime.default_allocator())
	defer runtime.arena_destroy(&arena)

	symbols_collected := 0

	{
		context.allocator = runtime.arena_allocator(&arena)

		for fullpath in matches {
			if skip_file(filepath.base(fullpath)) {
				log.errorf("  -> Skipping file: %v", fullpath)
				continue
			}

			data, ok := os.read_entire_file(fullpath, context.allocator)

			if !ok {
				log.errorf("Failed to read file for indexing: %v", fullpath)
				continue
			}

			p := parser.Parser {
				err   = log_error_handler,
				warn  = log_warning_handler,
				flags = {.Optional_Semicolons},
			}

			dir := filepath.base(filepath.dir(fullpath, context.allocator))

			pkg := new(ast.Package)
			pkg.kind = .Normal
			pkg.fullpath = fullpath
			pkg.name = dir

			if dir == "runtime" {
				pkg.kind = .Runtime
			}

			file := ast.File {
				fullpath = fullpath,
				src      = string(data),
				pkg      = pkg,
			}

			ok = parser.parse_file(&p, &file)

			if !ok {
				if !strings.contains(fullpath, "builtin.odin") && !strings.contains(fullpath, "intrinsics.odin") {
					log.errorf("Parse error in file: %v", fullpath)
				}
				continue
			}

			uri := common.create_uri(fullpath, context.allocator)

			if ret := collect_symbols(&indexer.index.collection, file, uri.uri); ret == .None {
				symbols_collected += 1
				log.errorf("  -> Successfully indexed file: %v", fullpath)
			} else {
				log.errorf("Failed to collect symbols from file: %v (error: %v)", fullpath, ret)
			}

			runtime.arena_free_all(&arena)
		}
	}

	build_cache.loaded_pkgs[strings.clone(pkg_name, indexer.index.collection.allocator)] = PackageCacheInfo {
		timestamp = time.now(),
	}
	
	log.errorf("Package indexing complete: %v", pkg_name)
	log.errorf("  -> Files processed: %d/%d", symbols_collected, len(matches))
	log.errorf("  -> Package cached with timestamp: %v", time.now())
}

remove_index_file :: proc(uri: common.Uri) -> common.Error {
	ok: bool

	fullpath := uri.path

	when ODIN_OS == .Windows {
		fullpath, _ = filepath.to_slash(fullpath, context.temp_allocator)
	}

	corrected_uri := common.create_uri(fullpath, context.temp_allocator)

	for k, &v in indexer.index.collection.packages {
		for k2, v2 in v.symbols {
			if strings.equal_fold(corrected_uri.uri, v2.uri) {
				free_symbol(v2, indexer.index.collection.allocator)
				delete_key(&v.symbols, k2)
			}
		}

		for method, &symbols in v.methods {
			for i := len(symbols) - 1; i >= 0; i -= 1 {
				#no_bounds_check symbol := symbols[i]
				if strings.equal_fold(corrected_uri.uri, symbol.uri) {
					unordered_remove(&symbols, i)
				}
			}
		}
	}

	return .None
}

index_file :: proc(uri: common.Uri, text: string) -> common.Error {
	ok: bool

	fullpath := uri.path

	p := parser.Parser {
		err   = log_error_handler,
		warn  = log_warning_handler,
		flags = {.Optional_Semicolons},
	}

	when ODIN_OS == .Windows {
		correct := common.get_case_sensitive_path(fullpath, context.temp_allocator)
		fullpath, _ = filepath.to_slash(correct, context.temp_allocator)
	}

	dir := filepath.base(filepath.dir(fullpath, context.temp_allocator))

	pkg := new(ast.Package)
	pkg.kind = .Normal
	pkg.fullpath = fullpath
	pkg.name = dir

	if dir == "runtime" {
		pkg.kind = .Runtime
	}

	file := ast.File {
		fullpath = fullpath,
		src      = text,
		pkg      = pkg,
	}

	ok = parser.parse_file(&p, &file)

	if !ok {
		if !strings.contains(fullpath, "builtin.odin") && !strings.contains(fullpath, "intrinsics.odin") {
			log.errorf("error in parse file for indexing %v", fullpath)
		}
	}

	corrected_uri := common.create_uri(fullpath, context.temp_allocator)

	for k, &v in indexer.index.collection.packages {
		for k2, v2 in v.symbols {
			if corrected_uri.uri == v2.uri {
				free_symbol(v2, indexer.index.collection.allocator)
				delete_key(&v.symbols, k2)
			}
		}

		for method, &symbols in v.methods {
			for i := len(symbols) - 1; i >= 0; i -= 1 {
				#no_bounds_check symbol := symbols[i]
				if corrected_uri.uri == symbol.uri {
					unordered_remove(&symbols, i)
				}
			}
		}
	}

	if ret := collect_symbols(&indexer.index.collection, file, corrected_uri.uri); ret != .None {
		log.errorf("failed to collect symbols on save %v", ret)
	}

	return .None
}


setup_index :: proc() {
	build_cache.loaded_pkgs = make(map[string]PackageCacheInfo, 50, context.allocator)
	symbol_collection := make_symbol_collection(context.allocator, &common.config)
	indexer.index = make_memory_index(symbol_collection)

	dir_exe := common.get_executable_path(context.temp_allocator)
	builtin_path := path.join({dir_exe, "builtin"}, context.temp_allocator)

	if os.exists(builtin_path) {
		try_build_package(builtin_path)
		return
	}

	root_path := os.get_env("ODIN_ROOT", context.temp_allocator)
	root_builtin_path := path.join({root_path, "/base/builtin"}, context.temp_allocator)

	if !os.exists(builtin_path) {
		log.errorf("Failed to find the builtin folder at `%v` or `%v`", builtin_path, root_builtin_path)
		return
	}

	try_build_package_debug(builtin_path)
}

free_index :: proc() {
	delete_symbol_collection(indexer.index.collection)
}

log_error_handler :: proc(pos: tokenizer.Pos, msg: string, args: ..any) {
	log.warnf("%v %v %v", pos, msg, args)
}

log_warning_handler :: proc(pos: tokenizer.Pos, msg: string, args: ..any) {
	log.warnf("%v %v %v", pos, msg, args)
}
