# bashcov/SimpleCov scope: measure product code only (actions/ + lib/); the test harness and
# CI scripts are not part of the shipped surface.
SimpleCov.start do
  add_filter %r{^/tests/}
  add_filter %r{^/scripts/}
end
