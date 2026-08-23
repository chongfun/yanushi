class PropertyTaxReviewResolutionsController < ApplicationController
  before_action :set_property

  def create
    tax_year_obj = TaxReporting::TaxYear.parse(resolution_params[:tax_year])
    unless tax_year_obj
      redirect_to schedule_e_property_path(@property, year: Date.current.year),
                  alert: "Invalid tax year '#{resolution_params[:tax_year]}'."
      return
    end

    @resolution = @property.tax_review_resolutions.build(resolution_params)
    redirect_year = params[:return_to_year].presence || @resolution.tax_year

    if @resolution.save
      redirect_to schedule_e_property_path(@property, year: redirect_year),
                  notice: "Tax treatment for Journal Entry ##{@resolution.journal_entry_id} was successfully recorded."
    else
      redirect_to schedule_e_property_path(@property, year: redirect_year),
                  alert: "Failed to record tax treatment: #{@resolution.errors.full_messages.to_sentence}"
    end
  rescue ActiveRecord::RecordNotUnique
    existing = @property.tax_review_resolutions.find_by(
      tax_year: resolution_params[:tax_year],
      journal_entry_id: resolution_params[:journal_entry_id]
    )
    redirect_year = params[:return_to_year].presence || resolution_params[:tax_year]
    if existing
      existing.update(
        treatment: resolution_params[:treatment],
        schedule_e_category: resolution_params[:schedule_e_category],
        notes: resolution_params[:notes]
      )
      redirect_to schedule_e_property_path(@property, year: redirect_year),
                  notice: "Tax treatment for Journal Entry ##{existing.journal_entry_id} was successfully updated."
    else
      redirect_to schedule_e_property_path(@property, year: redirect_year),
                  alert: "Tax treatment has already been recorded for this entry."
    end
  end

  def destroy
    @resolution = @property.tax_review_resolutions.find(params[:id])
    redirect_year = params[:return_to_year].presence || @resolution.tax_year
    @resolution.destroy!
    redirect_to schedule_e_property_path(@property, year: redirect_year),
                notice: "Tax treatment resolution removed; review item restored."
  end

  private

    def set_property
      @property = authenticated_user.properties.find(params[:property_id])
    end

    def resolution_params
      params.require(:property_tax_review_resolution).permit(
        :journal_entry_id,
        :tax_year,
        :treatment,
        :schedule_e_category,
        :notes
      )
    end
end
