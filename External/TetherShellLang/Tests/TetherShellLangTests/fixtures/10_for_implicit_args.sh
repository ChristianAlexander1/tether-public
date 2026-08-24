#@ argv: one two three
for x; do
  echo "arg:$x"
done
echo "count=$#"
