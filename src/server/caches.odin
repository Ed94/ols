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
	MonolithicWalkData :: struct {
		packages: [dynamic]string,
		monolithic_roots: [dynamic]string,
	}
	
    walk_proc :: proc(info: os.File_Info, in_err: os.Errno, user_data: rawptr) -> (os.Error, bool) {
        pkgs := cast(^[dynamic]string)user_data

        if !info.is_dir {
            return nil, false
        }
        
        // Check for monolithic package file FIRST
        monolithic_path := filepath.join({info.fullpath, ".ODIN_MONOLITHIC_PACKAGE"}, context.temp_allocator)
        if os.exists(monolithic_path) {
					  log.errorf("Found monolithic package in collection: %s", info.fullpath)
            // This is a monolithic package. Add it and skip subdirectories.
            if !slice.contains(pkgs[:], info.fullpath) {
                append(pkgs, strings.clone(info.fullpath))
            }
            return nil, true // skip subdirectories of this monolithic package
        }
        
        // Not a monolithic package. Check for .odin files in this directory.
        matches, glob_err := filepath.glob(fmt.tprintf("%v/*.odin", info.fullpath))
        if glob_err == .None && len(matches) > 0 {
            if !slice.contains(pkgs[:], info.fullpath) {
                append(pkgs, strings.clone(info.fullpath))
            }
        }
        // Continue to subdirectories
        return nil, false
    }
    
	for k, v in common.config.collections {
		walk_data := MonolithicWalkData{
			packages = make([dynamic]string, context.temp_allocator),
			monolithic_roots = make([dynamic]string, context.temp_allocator),
		}

		log.errorf("Scanning collection '%s' at path: %s", k, v)
		
		filepath.walk(v, walk_proc, &walk_data)

		log.errorf("Found %d packages in collection '%s'", len(walk_data), k)

		for pkg in walk_data.packages {
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

DebugWalkContext :: struct {
	packages: [dynamic]string,
	total_dirs_visited: int,
	packages_found: int,
	monolithic_packages_found: int,
}

// Context for cache walking
CacheWalkContext :: struct {
    packages: ^[dynamic]string,
    dirs_checked: int,
    monolithic_found: int,
}

// Helper to check if a path is inside a monolithic package
is_inside_monolithic_package :: proc(path: string, monolithic_roots: []string) -> bool {
	for root in monolithic_roots {
		if strings.has_prefix(path, root) && path != root {
			// Check if it's actually a subdirectory, not just a prefix match
			relative := path[len(root):]
			if len(relative) > 0 && (relative[0] == '/' || relative[0] == '\\') {
				return true
			}
		}
	}
	return false
}