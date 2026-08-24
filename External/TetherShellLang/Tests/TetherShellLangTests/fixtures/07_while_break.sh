i=0
while true; do
  i=$((i + 1))
  if [ "$i" -eq 3 ]; then
    break
  fi
  echo "n$i"
done
echo "after:$i"
