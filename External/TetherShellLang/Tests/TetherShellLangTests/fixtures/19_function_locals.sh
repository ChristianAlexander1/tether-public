x=global
y=also-global
demo() {
  local x=local
  y=changed
  echo "in:$x/$y"
}
demo
echo "out:$x/$y"
