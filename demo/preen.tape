# Recording for README.md — build with:  vhs demo/preen.tape
Output demo/preen.gif

Set Shell "bash"
Set FontSize 13
Set Width 1500
Set Height 820
Set Padding 24
Set Framerate 24
Set TypingSpeed 55ms
Set Theme { "name": "roost", "background": "#211e38", "foreground": "#c8c3e0", "cursor": "#bd93f9", "selection": "#3a3558", "black": "#211e38", "red": "#ff5555", "green": "#50fa7b", "yellow": "#f1fa8c", "blue": "#7c6ff0", "magenta": "#bd93f9", "cyan": "#8be9fd", "white": "#c8c3e0", "brightBlack": "#8a84b0", "brightRed": "#ff6e6e", "brightGreen": "#69ff94", "brightYellow": "#ffffa5", "brightBlue": "#9d8df5", "brightMagenta": "#d6acff", "brightCyan": "#a4ffff", "brightWhite": "#e0dcf5" }

Hide
Type 'export PATH="$HOME/.local/bin:$PATH"; export PS1="\[\e[38;2;124;111;240m\]❯\[\e[0m\] "'
Enter
Type "cd /tmp/preen-demo-repo && clear"
Enter
Sleep 1s
Show

# --- diffs, side by side ---
Type "preen diff"
Enter
Sleep 3s

Down
Sleep 1500ms
Down
Sleep 2s

Ctrl+D
Sleep 900ms
Ctrl+D
Sleep 1500ms

# --- flip to inline ---
Ctrl+S
Sleep 2500ms

Up
Sleep 2s

Ctrl+S
Sleep 2s

Escape
Sleep 800ms

# --- markdown ---
Type "preen md ."
Enter
Sleep 3s
Ctrl+D
Sleep 1200ms
Ctrl+D
Sleep 2s
Screenshot demo/preen-md.png
Escape
Sleep 1s
