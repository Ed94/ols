package server


import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "src:common"

dir_blacklist :: []string{"node_modules", ".git"}

@(private)
walk_dir :: proc(info: os.File_Info, in_err: os.Errno, user_data: rawptr) -> (err: os.Error, skip_dir: bool) {
	data := cast(^WalkData)user_data

	if info.is_dir {
		dir, _ := filepath.to_slash(info.fullpath, context.temp_allocator)
		dir_name := filepath.base(dir)

		// Check blacklist
		for blacklist in dir_blacklist {
			if blacklist == dir_name {
				return nil, true
			}
		}

		// Check for monolithic package
		monolithic_path := filepath.join({dir, ".ODIN_MONOLITHIC_PACKAGE"}, context.temp_allocator)
		if os.exists(monolithic_path) {
            log.errorf("Found monolithic package at: %s", dir)
			append(data.packages, dir)
			append(data.monolithic_roots, strings.clone(dir, context.temp_allocator))
			// Skip subdirectories - they're all part of this monolithic package
			return nil, true
		}
		
		// If not monolithic, treat as regular package
        log.errorf("Found regular package at: %s", dir)
		append(data.packages, dir)
	}

	return nil, false
}

// Context for tracking traversal progress
WalkTrackingContext :: struct {
    packages: ^[dynamic]string,
    monolithic_packages: [dynamic]string,
    total_dirs_visited: int,
    monolithic_count: int,
    workspace_root: string,
}

@(private)
walk_dir_with_tracking :: proc(info: os.File_Info, in_err: os.Errno, user_data: rawptr) -> (err: os.Error, skip_dir: bool) {
    context_data := cast(^WalkTrackingContext)user_data
    
    if info.is_dir {
        dir, _ := filepath.to_slash(info.fullpath, context.temp_allocator)
        dir_name := filepath.base(dir)
        
        context_data.total_dirs_visited += 1

        // Skip blacklisted directories
        for blacklist in dir_blacklist {
            if blacklist == dir_name {
                log.debugf("Skipping blacklisted directory: %v", dir)
                return nil, true
            }
        }
        
        // Add to packages list
        append(context_data.packages, dir)

        // Check for monolithic package
        monolithic_path := filepath.join({dir, ".ODIN_MONOLITHIC_PACKAGE"}, context.temp_allocator)
        if os.exists(monolithic_path) {
            // Record the monolithic package
            append(&context_data.monolithic_packages, strings.clone(dir))
            context_data.monolithic_count += 1
            
            log.infof("Monolithic package #%d found at: %v (visited %d dirs total)", 
                      context_data.monolithic_count, dir, context_data.total_dirs_visited)
            
            // Skip this directory's children but continue with siblings/other branches
            return nil, true // This tells filepath.walk to skip subdirectories of THIS directory only
        }

        // Regular directory, continue traversing its subdirectories
        return nil, false
    }

    return nil, false
}


WalkData :: struct {
	packages: ^[dynamic]string,
	monolithic_roots: ^[dynamic]string,
}


// Modified get_workspace_symbols with better tracking
get_workspace_symbols :: proc(query: string) -> (workspace_symbols: []WorkspaceSymbol, ok: bool) {
	workspace := common.config.workspace_folders[0]
	uri       := common.parse_uri(workspace.uri, context.temp_allocator) or_return
	pkgs      := make([dynamic]string, 0, context.temp_allocator)
	monolithic_roots := make([dynamic]string, 0, context.temp_allocator)
	symbols   := make([dynamic]WorkspaceSymbol, 0, 100, context.temp_allocator)

	
	walk_data := WalkData{
		packages = & pkgs,
		monolithic_roots = &monolithic_roots,
	}


	filepath.walk(uri.path, walk_dir, &walk_data)

    // Process packages for symbols (existing logic)
    _pkg: for pkg in pkgs {
        matches, err := get_package_files(pkg, context.temp_allocator)
        if len(matches) == 0 {
            continue
        }

        // Check exclusion paths
        for exclude_path in common.config.profile.exclude_path {
            exclude_forward, _ := filepath.to_slash(exclude_path, context.temp_allocator)

            if exclude_forward[len(exclude_forward) - 2:] == "**" {
                lower_pkg := strings.to_lower(pkg)
                lower_exclude := strings.to_lower(exclude_forward[:len(exclude_forward) - 3])
                if strings.contains(lower_pkg, lower_exclude) {
                    continue _pkg
                }
            } else {
                lower_pkg := strings.to_lower(pkg)
                lower_exclude := strings.to_lower(exclude_forward)
                if lower_pkg == lower_exclude {
                    continue _pkg
                }
            }
        }

        try_build_package_debug(pkg)

        if results, ok := fuzzy_search(query, {pkg}); ok {
            for result in results {
                symbol := WorkspaceSymbol {
                    name = result.symbol.name,
                    location = {range = result.symbol.range, uri = result.symbol.uri},
                    kind = symbol_kind_to_type(result.symbol.type),
                }
                append(&symbols, symbol)
            }
        }
    }
    
    return symbols[:], true
}
