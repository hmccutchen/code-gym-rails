module Admin
  class JudgeSolvesController < Admin::BaseController
    def index
      @listing = JudgeSolve::Listing.new(**filter_params)
      @counts = JudgeSolve::Counts.new
    end

    def update
      solve = JudgeSolve.readable.find(params[:id])
      saved = solve.update(human_call: verdict_params[:human_call].presence, human_note: verdict_params[:human_note].presence)
      flash_message = saved ? { notice: t("flash.admin.judge_solves.saved") } : { alert: t("flash.admin.judge_solves.refused") }
      listing = JudgeSolve::Listing.new(**filter_params)
      redirect_to admin_judge_solves_path(**listing.filters, anchor: helpers.dom_id(solve)), **flash_message
    end

    private

    def filter_params
      params.permit(:source, :show, :call, :n, :page).to_h.symbolize_keys
    end

    def verdict_params
      params.fetch(:judge_solve, {}).permit(:human_call, :human_note)
    end
  end
end
