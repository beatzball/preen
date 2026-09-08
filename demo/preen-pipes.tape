# Pipe recording for README.md — build with:
#   ./demo/seed-repo.sh /tmp/preen-demo-repo && vhs demo/preen-pipes.tape
Output demo/preen-pipes.gif

# Narrow on purpose: piped output is rendered 80 columns wide, so a wider
# frame would just be empty on the right.

Set Shell "bash"
Set FontSize 13
Set Width 740
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

# --- a diff on stdin goes to delta ---
Type "git diff | preen"
Enter
Sleep 3s
Space
Sleep 2500ms
Type "q"
Sleep 800ms

# --- anything else goes to glow ---
Type "cat docs/api.md | preen"
Enter
Sleep 4s
Type "q"
Sleep 1s
