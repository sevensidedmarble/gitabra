local u = require("gitabra.util")
local job = require("gitabra.job")
local api = vim.api

local singleton

local function git_has_staged_changes()
    local j = u.system_async({"git", "diff", "--cached", "--exit-code"}, {split_lines=true})
    job.wait(j, 1000)
    assert(j.done == true)
    return j.exit_code
end

-- This script used together with `git commit` to make sure
-- that `git commit` is held open/running until a specific external
-- signal is received. In this case, we're waiting the existance of a
-- file to be the signal to exit.
local function make_editor_script(params)
    return u.interp([[sh -c "
echo $1
while [ ! -f ${temppath}.exit ];
    do sleep 0.10
done
exit 0"]], params)
end

local function finish_commit()
    local commit_state = singleton
    if commit_state then
        singleton = nil
        u.system_async({'touch', commit_state.temppath..".exit"})
        job.wait(commit_state.job, 1000)
        if #commit_state.job.err_output ~= 0 then
            vim.cmd(string.format("echom '%s'",
                u.remove_trailing_newlines(table.concat(commit_state.job.err_output))))
        end
    end
end

local function gitabra_commit(mode)
    if mode ~= "amend" then
        local has_changes = git_has_staged_changes()
        if has_changes == 0 then
            print("No staged changes to commit")
            return
        end
    end

    -- Start `git commit` and hold the process open
    local temppath = vim.fn.tempname()

    local cmd = {"git", "commit"}
    if mode == "amend" then
        table.insert(cmd, "--amend")
    end

    local j = u.system_async(cmd, {
            env = {
                -- Give `git commit` a shell command to run.
                -- We will signal the shell command to terminate after the user
                -- saves and exits from editing the commit message
                string.format("GIT_EDITOR=%s", make_editor_script({temppath=temppath})),

                -- Help git locate the user's .gitconfig file
                string.format("HOME=%s", vim.fn.expand("~"))
            }
        })

    -- The shell script should send back the location of the commit message file
    job.wait_for(j, 3000, function()
        if not u.table_is_empty(j.output) then
            return true
        end
    end)
    assert(not u.str_is_really_empty(j.output[1]), "Expected to receive the EDITMSG file path, but timedout")

    -- Start editing the commit message file
    -- vim.cmd(string.format('e %s', vim.fn.fnameescape(u.git_dot_git_dir().."/COMMIT_EDITMSG")))

    vim.cmd(string.format('e %s', vim.fn.fnameescape(u.remove_trailing_newlines(j.output[1]))))

    -- Make sure this buffer goes away once it is hidden
    local bufnr = api.nvim_get_current_buf()
    vim.bo[bufnr].bufhidden = "wipe"
    vim.bo[bufnr].swapfile = false

    u.nvim_commands([[
        augroup ReleaseGitCommit
          autocmd! * <buffer>
          autocmd BufWritePost <buffer> lua require('gitabra.git_commit').finish_commit('WritePost')
          autocmd BufWinLeave <buffer> lua require('gitabra.git_commit').finish_commit('BufWinLeave')
          autocmd BufWipeout <buffer> lua require('gitabra.git_commit').finish_commit('BufWipeout')
        augroup END
        ]], true)

    singleton = {
        temppath = temppath,
        job = j,
    }
end

return {
    make_editor_script = make_editor_script,
    gitabra_commit = gitabra_commit,
    finish_commit = finish_commit,
}
