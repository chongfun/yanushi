class PropertyTaxProfilesController < ApplicationController
  before_action :set_property
  before_action :set_tax_profile, only: %i[edit update]

  def new
    year = TaxReporting::TaxYear.parse(params[:tax_year], default: Date.current.year)&.to_i || Date.current.year
    @tax_profile = @property.tax_profiles.build(tax_year: year)
  end

  def create
    @tax_profile = @property.tax_profiles.build(create_tax_profile_params)

    if @tax_profile.save
      redirect_to schedule_e_property_path(@property, year: @tax_profile.tax_year),
                  notice: "Tax classification for #{@tax_profile.tax_year} was successfully configured."
    else
      render :new, status: :unprocessable_content
    end
  rescue ActiveRecord::RecordNotUnique
    existing = @property.tax_profiles.find_by(tax_year: create_tax_profile_params[:tax_year])
    @tax_profile = existing || @tax_profile
    @tax_profile.errors.add(:tax_year, "has already been taken")
    render :new, status: :unprocessable_content
  end

  def edit
  end

  def update
    if @tax_profile.update(update_tax_profile_params)
      redirect_to schedule_e_property_path(@property, year: @tax_profile.tax_year),
                  notice: "Tax classification for #{@tax_profile.tax_year} was successfully updated."
    else
      render :edit, status: :unprocessable_content
    end
  end

  private

    def set_property
      @property = authenticated_user.properties.find(params[:property_id])
    end

    def set_tax_profile
      @tax_profile = @property.tax_profiles.find(params[:id])
    end

    def create_tax_profile_params
      params.require(:property_tax_profile).permit(
        :tax_year,
        :schedule_e_property_type,
        :other_description
      )
    end

    def update_tax_profile_params
      params.require(:property_tax_profile).permit(
        :schedule_e_property_type,
        :other_description
      )
    end
end
