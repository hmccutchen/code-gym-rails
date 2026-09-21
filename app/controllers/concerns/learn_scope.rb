# The Learn tab's slice of the vocabularies and the boundary checks on the
# :bucket/:concept a URL carries, shared by every controller that takes them.
#
# :bucket and :concept arrive from a URL, so they are held to the closed
# vocabulary here rather than trusted downstream — the same boundary rule
# ProblemSetIngest applies to provider output. An unknown pair is a 404, not a
# page rendering an empty concept. Validating the bucket against the user's
# own slice also means a user cannot browse the language they are not
# assigned by typing the URL.
module LearnScope
  extend ActiveSupport::Concern

  private

  def learn_buckets
    ConceptBucket.slice_for(current_user.language)
  end

  def validated_bucket
    bucket = params[:bucket].to_s
    raise ActiveRecord::RecordNotFound unless learn_buckets.include?(bucket)

    bucket
  end

  def validated_concept(bucket)
    concept = params[:concept].to_s
    raise ActiveRecord::RecordNotFound unless ConceptBucket.vocabulary_for(bucket).include?(concept)

    concept
  end
end
