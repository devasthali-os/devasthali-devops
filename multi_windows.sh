#!/bin/bash

# Create a new tmux session named 'mySession' and detach from it
tmux new-session -d -s mySession

# Split the tmux window into two horizontal panes
tmux split-window -v

# Split the upper pane horizontally to create a third pane on the right
tmux split-window -h -t mySession:0.0

# Run 'tail -f docker-lima.yaml' in the upper left pane
tmux send-keys -t mySession:0.0 'tail -f docker-lima.yaml' C-m

# Run 'tail -f README.md' in the lower pane
tmux send-keys -t mySession:0.1 'tail -f README.md' C-m

# Run 'docker ps' in the upper right pane (third pane)
tmux send-keys -t mySession:0.2 'docker ps' C-m

# Focus on the upper right pane
tmux select-pane -t mySession:0.2

# Attach to the tmux session
tmux attach-session -t mySession




