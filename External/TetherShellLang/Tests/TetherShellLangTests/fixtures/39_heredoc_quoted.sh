x=expanded
cat <<'EOF'
$x stays literal
EOF
cat <<"EOT"
also $x literal
EOT
echo done
