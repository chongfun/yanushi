class PropertyTaxReviewResolutionsController < ApplicationController
  before_action :set_property

  def create
    tax_year_obj = TaxReporting::TaxYear.parse(resolution_params[:tax_year])
    unless tax_year_obj
      redirect_year = parse_return_to_year(default_year: Date.current.year)
      return respond_to do |format|
        format.html { redirect_to schedule_e_property_path(@property, year: redirect_year), alert: "Invalid tax year '#{resolution_params[:tax_year]}'." }
        format.turbo_stream { head :bad_request }
      end
    end

    @resolution = @property.tax_review_resolutions.build(resolution_params)
    @year = parse_return_to_year(default_year: @resolution.tax_year)

    saved, is_update = begin
      if @resolution.save
        [ true, false ]
      else
        [ false, false ]
      end
    rescue ActiveRecord::RecordNotUnique
      existing = @property.tax_review_resolutions.find_by(
        tax_year: resolution_params[:tax_year],
        journal_entry_id: resolution_params[:journal_entry_id]
      )
      if existing
        updated = existing.update(
          treatment: resolution_params[:treatment],
          schedule_e_category: resolution_params[:schedule_e_category],
          notes: resolution_params[:notes]
        )
        [ updated, true ]
      else
        @resolution.errors.add(:journal_entry_id, "has already been resolved for this tax year")
        [ false, false ]
      end
    end

    @schedule_e_result = TaxReporting::ScheduleEQuery.call(property: @property, tax_year: @year)
    @tax_profile = @schedule_e_result.tax_profile
    @form_definition = TaxReporting::ScheduleEFormDefinition.for(@year)
    @active_years = Accounting::ActiveYearsQuery.call(property: @property, additional_years: [ @year ])

    respond_to do |format|
      if saved
        action_verb = is_update ? "updated" : "recorded"
        format.html do
          redirect_to schedule_e_property_path(@property, year: @year),
                      notice: "Tax treatment for Journal Entry ##{@resolution.journal_entry_id} was successfully #{action_verb}."
        end
        format.turbo_stream
      else
        format.html do
          redirect_to schedule_e_property_path(@property, year: @year),
                      alert: "Failed to record tax treatment: #{@resolution.errors.full_messages.to_sentence}"
        end
        format.turbo_stream do
          flash.now[:alert] = "Failed to record tax treatment: #{@resolution.errors.full_messages.to_sentence}"
          render turbo_stream: turbo_stream.replace(
            "schedule_e_review",
            partial: "properties/schedule_e/review",
            locals: { failed_resolution: @resolution }
          ), status: :unprocessable_content
        end
      end
    end
  end

  def destroy
    @resolution = @property.tax_review_resolutions.find(params[:id])
    @year = parse_return_to_year(default_year: @resolution.tax_year)
    @resolution.destroy!

    @schedule_e_result = TaxReporting::ScheduleEQuery.call(property: @property, tax_year: @year)
    @tax_profile = @schedule_e_result.tax_profile
    @form_definition = TaxReporting::ScheduleEFormDefinition.for(@year)
    @active_years = Accounting::ActiveYearsQuery.call(property: @property, additional_years: [ @year ])

    respond_to do |format|
      format.html do
        redirect_to schedule_e_property_path(@property, year: @year),
                    notice: "Tax treatment resolution removed; review item restored."
      end
      format.turbo_stream
    end
  end

  private

    def set_property
      @property = authenticated_user.properties.find(params[:property_id])
    end

    def parse_return_to_year(default_year:)
      if params[:return_to_year].present?
        parsed = TaxReporting::TaxYear.parse(params[:return_to_year], default: nil)
        return parsed.to_i if parsed
      end

      TaxReporting::TaxYear.parse(default_year, default: Date.current.year)&.to_i || Date.current.year
    end

    def resolution_params
      permitted = params.require(:property_tax_review_resolution).permit(
        :journal_entry_id,
        :tax_year,
        :treatment,
        :schedule_e_category,
        :notes
      )
      permitted[:schedule_e_category] = permitted[:schedule_e_category].presence if permitted[:treatment] == "map_to_schedule_e_category"
      permitted[:schedule_e_category] = nil unless permitted[:treatment] == "map_to_schedule_e_category"
      permitted
    end
end
