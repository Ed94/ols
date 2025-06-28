package server

import "src:common"

import "core:fmt"
import "core:log"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"

//Used in semantic tokens and inlay hints to handle the entire file being resolved.

FileResolve :: struct {
	symbols: map[uintptr]SymbolAndNode,
}


FileResolveCache :: struct {
	files: map[string]FileResolve,
}

file_resolve_cache: FileResolveCache

resolve_entire_file_cached :: proc(document: ^Document) -> map[uintptr]SymbolAndNode {
	if document.uri.uri not_in file_resolve_cache.files {
		file_resolve_cache.files[document.uri.uri] = FileResolve {
			symbols = resolve_entire_file(document, .None, virtual.arena_allocator(document.allocator)),
		}
	}

	return file_resolve_cache.files[document.uri.uri].symbols
}

BuildCache :: struct {
	loaded_pkgs: map[string]PackageCacheInfo,
	pkg_aliases: map[string][dynamic]string,
}

PackageCacheInfo :: struct {
	timestamp: time.Time,
}

build_cache: BuildCache


clear_all_package_aliases :: proc() {
	for collection_name, alias_array in build_cache.pkg_aliases {
		for alias in alias_array {
			delete(alias)
		}
		delete(alias_array)
	}

	clear(&build_cache.pkg_aliases)
}

//Go through all the collections to find all the possible packages that exists
find_all_package_aliases :: proc() {
	walk_proc :: proc(info: os.File_Info, in_err: os.Errno, user_data: rawptr) -> (os.Error, bool) {
		pkgs := cast(^[dynamic]string)user_data

		// We only process directories.
		if !info.is_dir {
			return nil, false
 		}
		
		// Check for monolithic package file.
		monolithic_path := filepath.join({info.fullpath, ".ODIN_MONOLITHIC_PACKAGE"}, context.temp_allocator)
		if os.exists(monolithic_path) {
			// This is a monolithic package. Add it and don't descend further.
			if !slice.contains(pkgs[:], info.fullpath) {
				append(pkgs, strings.clone(info.fullpath))
			}
			return nil, true // skip subdirectories
		}
		
		// Not a monolithic package. Check for .odin files in this directory.
		matches, glob_err := filepath.glob(fmt.tprintf("%v/*.odin", info.fullpath))
		if glob_err == .None && len(matches) > 0 {
			if !slice.contains(pkgs[:], info.fullpath) {
				append(pkgs, strings.clone(info.fullpath))
			}
		}
		return nil, false
	}

	when (false) {
	walk_proc :: proc(info: os.File_Info, in_err: os.Errno, user_data: rawptr) -> (err: os.Errno, skip_dir: bool) {
		data := cast(^[dynamic]string)user_data

		if !info.is_dir && filepath.ext(info.name) == ".odin" {
			dir := filepath.dir(info.fullpath, context.temp_allocator)
			if !slice.contains(data[:], dir) {
				append(data, dir)
			}
		}

		return in_err, false
	}
	}

	for k, v in common.config.collections {
		pkgs := make([dynamic]string, context.temp_allocator)
		filepath.walk(v, walk_proc, &pkgs)

		for pkg in pkgs {
			if pkg, err := filepath.rel(v, pkg, context.temp_allocator); err == .None {
				forward_pkg, _ := filepath.to_slash(pkg, context.temp_allocator)
				if k not_in build_cache.pkg_aliases {
					build_cache.pkg_aliases[k] = make([dynamic]string)
				}

				aliases := &build_cache.pkg_aliases[k]

				append(aliases, strings.clone(forward_pkg))
			}
		}
	}
}
