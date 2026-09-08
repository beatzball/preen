# Markdown screenshot for README.md — build with:
#   ./demo/seed-repo.sh /tmp/preen-demo-repo && vhs demo/preen-md.tape
#
# Screenshot needs a relative path and a Sleep after it, or vhs writes nothing.
# Output only understands gif/webm/mp4, so the line below is ignored and the
# Screenshot is what writes the file. The tape ends on the same view anyway, so
# a future vhs that does write PNGs would write the same picture.
Output demo/preen-md.png

Set Shell "bash"
Set FontSize 13
Set Width 1400
Set Height 620
Set Padding 24
Set Framerate 20
Set TypingSpeed 55ms
Set Theme { "name": "roost", "background": "#211e38", "foreground": "#c8c3e0", "cursor": "#bd93f9", "selection": "#3a3558", "black": "#211e38", "red": "#ff5555", "green": "#50fa7b", "yellow": "#f1fa8c", "blue": "#7c6ff0", "magenta": "#bd93f9", "cyan": "#8be9fd", "white": "#c8c3e0", "brightBlack": "#8a84b0", "brightRed": "#ff6e6e", "brightGreen": "#69ff94", "brightYellow": "#ffffa5", "brightBlue": "#9d8df5", "brightMagenta": "#d6acff", "brightCyan": "#a4ffff", "brightWhite": "#e0dcf5" }

Hide
Type 'export PATH="$HOME/.local/bin:$PATH"; export PS1="\[\e[38;2;124;111;240m\]❯\[\e[0m\] "'
Enter
Type "cd /tmp/preen-demo-repo && clear"
Enter
Sleep 1s
Show

# docs, not ".": md mode walks every directory, and the worktrees under
# .worktrees/ hold their own copy of each file.
Type "preen md docs"
Enter
Sleep 3s
Screenshot demo/preen-md.png
Sleep 2s
