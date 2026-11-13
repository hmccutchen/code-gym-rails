# Solid Queue runs lower numbers first within a queue, so each step down this list waits for the ones above it.
module JobPriority
  CLICK      = 0
  SCHEDULED  = 10
  BACKGROUND = 20
end
