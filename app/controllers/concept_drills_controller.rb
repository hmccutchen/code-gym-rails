# Persists nothing: ConceptDrills owns the rows and the cap.
class ConceptDrillsController < ApplicationController
  include LearnScope

  # POST /learn/:bucket/:concept/drill
  def create
    bucket  = validated_bucket
    concept = validated_concept(bucket)

    start(concept.humanize) { ConceptDrills.start(current_user, concept: concept, bucket: bucket) }
    redirect_to learn_concept_path(bucket: bucket, concept: concept)
  end

  # DELETE /learn/:bucket/:concept/drill
  def destroy
    bucket  = validated_bucket
    concept = validated_concept(bucket)

    group = ConceptDrills.stop!(current_user, concept: concept, bucket: bucket)
    name  = group ? t("learn.groups.#{group}") : concept.humanize
    redirect_to learn_concept_path(bucket: bucket, concept: concept), notice: t("learn.drill.stopped", name: name)
  end

  # POST /learn/:bucket/groups/:group/drill
  def create_group
    bucket = validated_bucket
    group  = validated_group(bucket)

    start(t("learn.groups.#{group}")) { ConceptDrills.start_group(current_user, group: group, bucket: bucket) }
    redirect_to learn_path(anchor: helpers.learn_group_anchor(bucket, group))
  end

  # DELETE /learn/:bucket/groups/:group/drill
  def destroy_group
    bucket = validated_bucket
    group  = validated_group(bucket)

    ConceptDrills.stop_group!(current_user, group: group, bucket: bucket)
    redirect_to learn_path(anchor: helpers.learn_group_anchor(bucket, group)),
                notice: t("learn.drill.stopped", name: t("learn.groups.#{group}"))
  end

  private

  def start(name)
    outcome = yield
    case outcome.status
    when :started, :already, :already_reserved
      flash[:notice] = t("learn.drill.#{outcome.status}", name: name)
    when :full
      flash[:alert] = helpers.drill_message("full", outcome.drills)
    else
      raise ArgumentError, "Unknown drill outcome: #{outcome.status}"
    end
  end

  def validated_group(bucket)
    group = params[:group].to_s
    raise ActiveRecord::RecordNotFound if ConceptDrills.concepts_in(group, bucket).empty?

    group
  end
end
