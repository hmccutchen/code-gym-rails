module PublicFileHelper
  DIGESTS = Concurrent::Map.new

  # Production caches public/ for a year, so a file's URL has to change whenever its bytes do.
  def versioned_public_path(name)
    digest = DIGESTS.compute_if_absent(name) { Digest::SHA256.file(Rails.public_path.join(name)).hexdigest.first(8) }
    "/#{name}?v=#{digest}"
  end
end
