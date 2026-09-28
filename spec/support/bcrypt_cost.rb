# Login codes are hashed at BCrypt's default cost, where one hash or compare
# takes about a quarter of a second. `login_as` does both, so at that cost
# hashing alone was most of the suite's runtime. The minimum cost still runs
# the real hash and compare; only production's resistance to brute force
# depends on the cost, and nothing here tests that.
BCrypt::Engine.cost = BCrypt::Engine::MIN_COST
