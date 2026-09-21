module ConceptDrillsHelper
  def drill_label(entry)
    entry.group ? t("learn.groups.#{entry.group}") : entry.concepts.first.humanize
  end

  def drill_names(drills)
    drills.entries.map { |entry| drill_label(entry) }.to_sentence
  end

  def drill_stop_path(entry)
    if entry.group
      learn_group_drill_path(bucket: entry.bucket, group: entry.group)
    else
      learn_concept_drill_path(bucket: entry.bucket, concept: entry.concepts.first)
    end
  end

  def learn_group_anchor(bucket, group)
    "learn-group-#{bucket}-#{group}"
  end
end
