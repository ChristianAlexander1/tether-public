a=1
b=2
if [ "$a" -eq 1 ]; then
  if [ "$b" -eq 2 ]; then
    echo "both"
  else
    echo "a-only"
  fi
fi
if [ "$a" -eq 9 ]; then
  echo "no"
else
  if [ "$b" -eq 9 ]; then
    echo "no2"
  else
    echo "neither"
  fi
fi
