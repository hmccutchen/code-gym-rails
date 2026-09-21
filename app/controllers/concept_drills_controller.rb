# Start and stop drills from the Learn tab. Persists nothing itself:
# ConceptDrills owns the rows and the cap, and this only turns its answers
# into a redirect and a flash.
class ConceptDrillsController < ApplicationController
  include LearnScope

  # POST /learn/:bucket/:concept/drill
  def create
    bucket  = validated_bucket
    concept = validated_concept(bucket)

    start(concept.humanize) { ConceptDrills.start!(current_user, concept: concept, bucket: bucket) }
    redirect_to learn_concept_path(bucket: bucket, concept: concept)
  end

  # DELETE /learn/:bucket/:concept/drill
  def destroy
    bucket  = validated_bucket
    concept = validated_concept(bucket)

    ConceptDrills.stop!(current_user, concept: concept, bucket: bucket)
    redirect_to learn_concept_path(bucket: bucket, concept: concept), notice: t("learn.drill.stopped", name: concept.humanize)
  end

  # POST /learn/:bucket/groups/:group/drill
  def create_group
    bucket = validated_bucket
    group  = validated_group(bucket)

    start(t("learn.groups.#{group}")) { ConceptDrills.start_group!(current_user, group: group, bucket: bucket) }
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
    started = yield
    flash[:notice] = t(started ? "learn.drill.started" : "learn.drill.already", name: name)
  rescue ConceptDrills::LimitReached
    flash[:alert] = t("learn.drill.full", drills: helpers.drill_names(ConceptDrills.for(current_user)))
  end

  def validated_group(bucket)
    group = params[:group].to_s
    raise ActiveRecord::RecordNotFound if ConceptDrills.concepts_in(group, bucket).empty?

    group
  end
end
