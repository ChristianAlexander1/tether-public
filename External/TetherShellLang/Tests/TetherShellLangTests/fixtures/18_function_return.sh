probe() {
  return 3
}
probe
echo "status=$?"
probe && echo "taken" || echo "not-taken"
