read -r raw <<'EOF'
C:\tether\bin
EOF
echo "[$raw]"
read cooked <<'EOF'
hello\ world
EOF
echo "[$cooked]"
