package server

import "core:strings"
import "core:slice"

import "src:common"


get_folding_ranges :: proc(document: ^Document) -> []FoldingRange {
	ranges: [dynamic]FoldingRange

	lines := strings.split_lines(string(document.text))

	for line_idx := 0; line_idx < len(lines); line_idx += 1 {
		line_content := lines[line_idx]
		trimmed_line := strings.trim_space(line_content)
		if strings.has_prefix(trimmed_line, "#region") || strings.has_prefix(trimmed_line, "#Region") {
			start_line := line_idx
			end_line := line_idx
			for i := line_idx + 1; i < len(lines); i += 1 {
				trimmed_next_line := strings.trim_space(lines[i])
				if strings.has_prefix(trimmed_next_line, "#endregion") || strings.has_prefix(trimmed_next_line, "#Endregion") {
					end_line = i
					break
				}
			}
			append(&ranges, FoldingRange{start_line = start_line, end_line = end_line, start_character = 0, end_character = 0, kind = "region"})
		}
	}

	return slice.clone(ranges[:], context.allocator)
}
