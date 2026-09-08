# bashcov/SimpleCov scope: measure product code only (actions/ + lib/); the test harness and
# CI scripts are not part of the shipped surface.
#
# The leading slash is optional on purpose: SimpleCov 0.x matched these filters against a
# root-relative path with a leading slash, 1.x matches without it. `^/?` matches under both,
# so this file does not become a flag day at the bashcov 3.x -> 4.x bump.
SimpleCov.start do
  add_filter %r{^/?tests/}
  add_filter %r{^/?scripts/}
end
