module LearnSearchHelper
  def learn_search_text(key, bucket:, group:)
    name = key.humanize
    words = [ name, group && t("learn.groups.#{group}"), t("learn.buckets.#{bucket}"),
              *Glossary.forms_for(name), *LearnSearchTerms.for(key) ]
    words.compact.map(&:downcase).uniq.join(" ")
  end
end
