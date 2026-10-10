# :bucket and :concept come from a URL, so an unknown pair or another language's bucket is a 404.
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
