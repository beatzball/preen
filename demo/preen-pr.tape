# Pull-request recording for README.md — build with:
#   ./demo/seed-repo.sh /tmp/preen-demo-repo && vhs demo/preen-pr.tape
# It reads a real public PR over the gh API. Nothing is cloned or checked out.
Output demo/preen-pr.gif

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
Type "cd /tmp/preen-demo-repo/.pr && clear"
Enter
# Warm the gh auth and DNS up off camera, so the real call is not a five
# second stare at an empty screen.
Type "gh pr diff 673 > /dev/null 2>&1; clear"
Enter
Sleep 6s
Show

Type "preen pr 673"
Enter
Sleep 800ms

# preen makes three gh calls before the picker opens, about three seconds of
# dead air. Skip it rather than record it.
Hide
Sleep 5s
Show

Sleep 1500ms
Down
Sleep 1800ms
Down
Sleep 2200ms

Ctrl+S
Sleep 2500ms

Escape
Sleep 1s
