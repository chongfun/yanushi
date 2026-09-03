class RentTermsController < ApplicationController
  before_action :set_tenancy

  def new
    current_term = @tenancy.current_rent_term
    @rent_term = @tenancy.rent_terms.new(
      effective_from: Date.current,
      amount_cents: current_term&.amount_cents,
      due_day: current_term&.due_day || 1,
      frequency: "monthly"
    )
  end

  def create
    amount_cents = if rent_term_params[:amount_cents].present?
      rent_term_params[:amount_cents].to_i
    elsif rent_term_params[:amount].present?
      (BigDecimal(rent_term_params[:amount].to_s) * 100).round
    end

    result = RentTerms::ChangeService.call(
      tenancy: @tenancy,
      amount_cents: amount_cents,
      effective_from: rent_term_params[:effective_from],
      due_day: rent_term_params[:due_day],
      frequency: rent_term_params[:frequency]
    )

    if result.success?
      @rent_term = result.value!.data[:rent_term]
      respond_to do |format|
        format.html { redirect_to tenancy_agreement_path(@tenancy), notice: "Rent was successfully updated." }
        format.json { render json: @rent_term, status: :created }
      end
    else
      @rent_term = (result.failure.data && result.failure.data[:rent_term]) || @tenancy.rent_terms.new(rent_term_params)
      @rent_term.errors.add(:base, result.failure.error) if @rent_term.errors.empty?
      respond_to do |format|
        format.html { render :new, status: :unprocessable_content }
        format.json { render json: @rent_term.errors, status: :unprocessable_content }
      end
    end
  end

  private

    def set_tenancy
      @tenancy = authenticated_user.tenancies.find(params.expect(:tenancy_id))
    end

    def rent_term_params
      params.expect(rent_term: %i[amount amount_cents due_day frequency effective_from])
    end
end
