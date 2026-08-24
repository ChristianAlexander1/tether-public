fact() {
  local n=$1
  if [ "$n" -le 1 ]; then
    echo 1
  else
    local m=$((n - 1))
    echo $((n * $(fact $m)))
  fi
}
echo "5! = $(fact 5)"
