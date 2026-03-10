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

local function shell_quote(s)
	return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function build_fzf_cmd(file_q)
	local git_log = string.format(
		"git log --format='%%h%%x09%%ad %%h %%s' --date=format:'%%Y-%%m-%%d %%H:%%M' --follow -- %s",
		file_q
	)
	local preview = string.format(
		"git diff {1} -- %s | delta --paging=never",
		file_q
	)
	return git_log
		.. " | fzf"
		.. " --delimiter='\\t'"
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

	local log_check = Command("git")
		:arg("log")
		:arg("--follow")
		:arg("--oneline")
		:arg("--")
		:arg(state.file)
		:cwd(state.dir)
		:stdout(Command.PIPED)
		:stderr(Command.PIPED)
		:output()

	if not log_check or log_check.stdout == "" then
		ya.notify({ title = "git-time-machine.yazi", content = "No git history for this file", level = "warn", timeout = 3 })
		return
	end

	local file_q = shell_quote(state.file)
	local cmd    = build_fzf_cmd(file_q)

	local permit = ui.hide()
	local child, spawn_err = Command("sh")
		:arg("-c")
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

	local hash = selected:match("^([^\t]+)")
	if not hash or hash == "" then
		ya.notify({ title = "git-time-machine.yazi", content = "Could not parse commit hash", level = "error", timeout = 3 })
		return
	end

	local filename = state.file:match("([^/]+)$")
	local yes = ya.confirm({
		pos   = { "center", w = 62, h = 10 },
		title = ui.Line("Restore file?"),
		body  = ui.Text(
			string.format("Restore '%s' from commit %s?\n\nThis will overwrite the current file.", filename, hash)
		):wrap(ui.Wrap.YES),
	})
	if not yes then return end

	local result, git_err = Command("git")
		:arg("restore")
		:arg("--source=" .. hash)
		:arg("--")
		:arg(state.file)
		:cwd(state.dir)
		:stdout(Command.PIPED)
		:stderr(Command.PIPED)
		:output()

	if not result or not result.status.success then
		local msg = (result and result.stderr ~= "" and result.stderr) or tostring(git_err)
		ya.notify({ title = "git-time-machine.yazi", content = "git restore failed: " .. msg, level = "error", timeout = 5 })
		return
	end

	ya.notify({
		title   = "git-time-machine.yazi",
		content = string.format("Restored '%s' from %s.", filename, hash),
		level   = "info",
		timeout = 3,
	})
end

return M
