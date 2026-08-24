#@ verify-env: GREETING=hello
export GREETING=hello
echo "shell:$GREETING"
demo() {
  local temp=7
  export temp
  echo "in:$temp"
}
demo
echo "after:${temp:-unset}"
