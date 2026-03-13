local M = {}

local get_state = ya.sync(function()
	local h = cx.active.current.hovered
	if not h or h.cha.is_dir then
		return nil
	end
	return {
		file = tostring(h.url),
		dir  = tostring(h.url.parent),
	}
end)

local function is_windows()
	return ya.target_os() == "windows"
end

local function shell_quote(s)
	if is_windows() then
		return '"' .. s:gsub('"', '""') .. '"'
	else
		return "'" .. s:gsub("'", "'\\''") .. "'"
	end
end

local function fetch_log_entries(file_path, dir)
	local output = Command("git")
		:arg("log")
		:arg("--follow")
		:arg("--name-only")
		:arg("--format=%h%x09%ad %h %s")
		:arg("--date=format:%Y-%m-%d %H:%M")
		:arg("--")
		:arg(file_path)
		:cwd(dir)
		:stdout(Command.PIPED)
		:stderr(Command.PIPED)
		:output()

	if not output or not output.status.success then return nil end

	local entries = {}
	local commit_line = nil
	for line in output.stdout:gmatch("[^\n]+") do
		if line ~= "" then
			if commit_line == nil then
				commit_line = line
			else
				table.insert(entries, commit_line .. "\t" .. line)
				commit_line = nil
			end
		end
	end
	return entries
end

local function write_temp_file(entries)
	local path
	if is_windows() then
		local tmpdir = os.getenv("TEMP") or os.getenv("TMP") or "C:\\Windows\\Temp"
		path = tmpdir .. "\\gtm_entries.txt"
	else
		path = "/tmp/gtm_entries.txt"
	end
	local f, err = io.open(path, "w")
	if not f then return nil, err end
	for _, entry in ipairs(entries) do
		f:write(entry .. "\n")
	end
	f:close()
	return path, nil
end

local function has_delta()
	local result = Command("delta"):arg("--version"):stdout(Command.PIPED):stderr(Command.PIPED):output()
	return result and result.status.success
end

local function build_fzf_cmd(temp_file, file_abs)
	local preview
	if has_delta() then
		if is_windows() then
			preview = string.format(
				"git diff {1}:{3} %s | delta --paging=never",
				shell_quote(file_abs)
			)
		else
			preview = string.format(
				"git diff {1}:'{3}' %s | delta --paging=never",
				shell_quote(file_abs)
			)
		end
	else
		if is_windows() then
			preview = string.format(
				"git diff --color=always {1}:{3} %s",
				shell_quote(file_abs)
			)
		else
			preview = string.format(
				"git diff --color=always {1}:'{3}' %s",
				shell_quote(file_abs)
			)
		end
	end

	local input_cmd
	if is_windows() then
		input_cmd = "type " .. shell_quote(temp_file) .. " | fzf"
	else
		input_cmd = "fzf < " .. shell_quote(temp_file)
	end

	return input_cmd
		.. " --delimiter='\t'"
		.. " --with-nth=2"
		.. " --preview=" .. shell_quote(preview)
		.. " --header 'ctrl-j/k: move  ctrl-r: clear  enter: restore  esc: cancel'"
		.. " --bind 'ctrl-r:clear-query+track-current'"
		.. " --bind 'ctrl-j:down'"
		.. " --bind 'ctrl-k:up'"
end

function M:entry()
	local state = get_state()
	if not state then
		ya.notify({ title = "git-time-machine.yazi", content = "No file hovered", level = "warn", timeout = 3 })
		return
	end

	local git_check = Command("git")
		:arg("rev-parse")
		:arg("--git-dir")
		:cwd(state.dir)
		:stdout(Command.PIPED)
		:stderr(Command.PIPED)
		:output()

	if not git_check or not git_check.status.success then
		ya.notify({ title = "git-time-machine.yazi", content = "Not a git repository", level = "warn", timeout = 3 })
		return
	end

	local entries = fetch_log_entries(state.file, state.dir)
	if not entries or #entries == 0 then
		ya.notify({ title = "git-time-machine.yazi", content = "No git history for this file", level = "warn", timeout = 3 })
		return
	end

	local temp_file, temp_err = write_temp_file(entries)
	if not temp_file then
		ya.notify({ title = "git-time-machine.yazi", content = "Temp file error: " .. tostring(temp_err), level = "error", timeout = 3 })
		return
	end

	local cmd = build_fzf_cmd(temp_file, state.file)

	local permit = ui.hide()
	local shell_cmd, shell_flag
	if is_windows() then
		shell_cmd, shell_flag = "cmd", "/c"
	else
		shell_cmd, shell_flag = "sh", "-c"
	end
	local child, spawn_err = Command(shell_cmd)
		:arg(shell_flag)
		:arg(cmd)
		:cwd(state.dir)
		:stdout(Command.PIPED)
		:stderr(Command.INHERIT)
		:spawn()

	if not child then
		permit:drop()
		ya.notify({ title = "git-time-machine.yazi", content = "Failed: " .. tostring(spawn_err), level = "error", timeout = 3 })
		return
	end

	local output, err = child:wait_with_output()
	permit:drop()

	if not output then
		ya.notify({ title = "git-time-machine.yazi", content = tostring(err), level = "error", timeout = 3 })
		return
	end
	if not output.status.success then
		return  -- Esc pressed or no commits; silent exit
	end

	local selected = output.stdout:gsub("\n$", "")
	if selected == "" then return end

	local hash      = selected:match("^([^\t]+)")
	local hist_path = selected:match("^[^\t]+\t[^\t]+\t([^\t]+)")
	if not hash or hash == "" then
		ya.notify({ title = "git-time-machine.yazi", content = "Could not parse commit hash", level = "error", timeout = 3 })
		return
	end
	if not hist_path or hist_path == "" then
		ya.notify({ title = "git-time-machine.yazi", content = "Could not parse historical path", level = "error", timeout = 3 })
		return
	end

	local filename = state.file:match("([^/\\]+)$")
	local yes = ya.confirm({
		pos   = { "center", w = 62, h = 10 },
		title = ui.Line("Restore file?"),
		body  = ui.Text(
			string.format("Restore '%s' from commit %s?\n\nThis will overwrite the current file.", filename, hash)
		):wrap(ui.Wrap.YES),
	})
	if not yes then return end

	local show_result, show_err = Command("git")
		:arg("show")
		:arg(hash .. ":" .. hist_path)
		:cwd(state.dir)
		:stdout(Command.PIPED)
		:stderr(Command.PIPED)
		:output()

	if not show_result or not show_result.status.success then
		local msg = (show_result and show_result.stderr ~= "" and show_result.stderr) or tostring(show_err)
		ya.notify({ title = "git-time-machine.yazi", content = "git restore failed: " .. msg, level = "error", timeout = 5 })
		return
	end

	local f, io_err = io.open(state.file, "wb")
	if not f then
		ya.notify({ title = "git-time-machine.yazi", content = "Write failed: " .. tostring(io_err), level = "error", timeout = 5 })
		return
	end
	f:write(show_result.stdout)
	f:close()

	ya.notify({
		title   = "git-time-machine.yazi",
		content = string.format("Restored '%s' from %s.", filename, hash),
		level   = "info",
		timeout = 3,
	})
end

return M
