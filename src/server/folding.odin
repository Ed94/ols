package server

import "core:strings"
import "core:slice"

import "src:common"

// Extract region label from a line like #region("Drop Down") or #region Helper Functions
extract_region_label :: proc(line: string) -> string {
	trimmed := strings.trim_space(line)
	
	// Handle #region("label") syntax
	if start_paren := strings.index_byte(trimmed, '('); start_paren != -1 {
		if end_paren := strings.last_index_byte(trimmed, ')'); end_paren != -1 && end_paren > start_paren {
			inside_parens := trimmed[start_paren+1:end_paren]
			// Remove quotes if present
			inside_parens = strings.trim_space(inside_parens)
			if len(inside_parens) >= 2 && inside_parens[0] == '"' && inside_parens[len(inside_parens)-1] == '"' {
				return inside_parens[1:len(inside_parens)-1]
			}
			return inside_parens
		}
	}
	
	// Handle #region text syntax (space-separated)
	words := strings.fields(trimmed)
	if len(words) > 1 {
		// Join all words after #region/#endregion
		return strings.join(words[1:], " ")
	}
	
	return "" // No label
}

// Check if line is a region start
is_region_start :: proc(line: string) -> bool {
	trimmed := strings.trim_space(line)
	return strings.has_prefix(trimmed, "#region") || strings.has_prefix(trimmed, "#Region")
}

// Check if line is a region end  
is_region_end :: proc(line: string) -> bool {
	trimmed := strings.trim_space(line)
	return strings.has_prefix(trimmed, "#endregion") || strings.has_prefix(trimmed, "#Endregion")
}

get_folding_ranges :: proc(document: ^Document) -> []FoldingRange {
	ranges: [dynamic]FoldingRange
	lines := strings.split_lines(string(document.text))
	
	// Simple approach since no nesting: find matching pairs
	for line_idx := 0; line_idx < len(lines); line_idx += 1 {
		line_content := lines[line_idx]
		
		if is_region_start(line_content) {
			start_label := extract_region_label(line_content)
			start_line := line_idx
			
			// Look for matching #endregion
			for end_line_idx := line_idx + 1; end_line_idx < len(lines); end_line_idx += 1 {
				end_line_content := lines[end_line_idx]
				
				if is_region_end(end_line_content) {
					end_label := extract_region_label(end_line_content)
					
					// Match if labels are the same, or if both are empty (unlabeled)
					if start_label == end_label {
						append(&ranges, FoldingRange{
							start_line = start_line,
							end_line = end_line_idx,
							start_character = 0,
							end_character = 0,
							kind = "region"
						})
						break // Found the matching pair, move on
					}
				}
			}
		}
	}
	
	return slice.clone(ranges[:], context.allocator)
}