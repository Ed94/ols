write-host 'Updating Dependencies..'

$path_odin    = 'C:\projects\SectrPrototype\toolchain\Odin\'
$path_root    = git rev-parse --show-toplevel
$path_ols     = $path_root
$url_ols_repo = 'https://github.com/Ed94/ols'
$path_build   = join-path $path_root 'build'

if ((test-path $path_build) -eq $false) {
	new-item -ItemType Directory -Path $path_build
}

function Update-GitRepo
{
	param( [string] $path, [string] $url, [string] $build_command )

	if ( $build_command -eq $null ) {
		write-host "Attempted to call Update-GitRepo without build_command specified"
		return
	}

	$repo_name = $url.Split('/')[-1].Replace('.git', '')

	# $last_built_commit = join-path $path_build "last_built_commit_$repo_name.txt"
	# if ( -not(test-path -Path $path))
	# {
	# 	write-host "Cloining repo from $url to $path"
	# 	git clone $url $path

	# 	write-host "Building $url"
	# 	push-location $path
	# 	& "$build_command"
	# 	pop-location

	# 	git -C $path rev-parse HEAD | out-file $last_built_commit
	# 	$script:binaries_dirty = $true
	# 	write-host
	# 	return
	# }

	git -C $path fetch
	# $latest_commit_hash = git -C $path rev-parse '@{u}'
	# $last_built_hash    = if (Test-Path $last_built_commit) { Get-Content $last_built_commit } else { "" }

	# if ( $latest_commit_hash -eq $last_built_hash ) {
	# 	write-host
	# 	return
	# }

	write-host "Build out of date for: $path, updating"
	write-host 'Pulling...'
	git -C $path pull

	write-host "Building $url"
	push-location $path
	& $build_command
	pop-location

	# $latest_commit_hash | out-file $last_built_commit
	$script:binaries_dirty = $true
	write-host
}

Push-Location $path_root

$env:odin = join-path $path_odin 'odin.exe'
Update-GitRepo -path $path_ols -url $url_ols_repo -build_command '.\build.bat'

remove-item env:odin

Pop-Location
