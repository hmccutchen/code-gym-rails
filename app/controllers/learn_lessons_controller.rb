# GET /learn/lessons/:lesson — read-only: nothing here calls a provider or writes a row.
class LearnLessonsController < ApplicationController
  def show
    @key    = params[:lesson].to_s
    @lesson = LearnLessons.find(@key) or raise ActiveRecord::RecordNotFound
  end
end
