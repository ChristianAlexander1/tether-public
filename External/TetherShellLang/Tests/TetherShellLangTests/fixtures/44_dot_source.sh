cat > lib.sh <<'EOF'
LIBVAR=from-library
greet() { echo "greet:$1"; }
EOF
. ./lib.sh
echo "var=$LIBVAR"
greet tether
