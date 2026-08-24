x=5
if [ "$x" -lt 3 ]; then
  echo "small"
elif [ "$x" -lt 10 ]; then
  echo "medium"
else
  echo "large"
fi
