# Design notes: docs/code-notes/app/services/account_deletion.md
class AccountDeletion
  Outcome = Data.define(:status)
  LOCK_ORDER = [ DailyExercise, DailyResponse, ConceptMastery ].freeze

  def self.call(user) = new(user.id).call

  def initialize(user_id)
    @user_id = user_id
  end

  def call
    User.transaction do
      owner = User.lock.find_by(id: @user_id)
      next Outcome.new(status: :already_deleted) unless owner

      LOCK_ORDER.each { |model| model.where(user_id: @user_id).order(:id).lock.ids }
      @global_ids = global_ids(owner)
      AccountData::FATES.each_value { |fate| apply(fate, owner) }
      Outcome.new(status: :deleted)
    end
  end

  private

  def apply(fate, owner)
    case fate.kind
    when :delete then fate.rows.call(owner).delete_all
    when :nullify then fate.rows.call(owner).update_all(fate.columns.index_with(nil))
    when :give_back_seat then owner.give_back_invite_seat!
    when :delete_unfinished then UnfinishedJobs.discard_naming(user_id: @user_id, global_ids: @global_ids)
    when :cascades, :keep then nil
    else raise ArgumentError, "Unhandled account data fate: #{fate.kind.inspect}"
    end
  end

  def global_ids(owner)
    [ owner, *DailyExercise.where(user_id: @user_id).select(:id), *DailyResponse.where(user_id: @user_id).select(:id) ]
      .map { |record| record.to_global_id.to_s }
  end
end
