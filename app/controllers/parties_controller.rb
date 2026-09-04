class PartiesController < ApplicationController
  before_action :set_party, only: %i[show edit update destroy]

  def index
    page = [ params[:page].to_i, 1 ].max
    @per_page = 25
    scope = authenticated_user.parties.includes(:party_aliases, :tenancy_parties).order(:display_name)
    @total_count = scope.count
    @total_pages = @total_count.zero? ? 0 : (@total_count.to_f / @per_page).ceil
    @page = @total_pages > 0 ? [ page, @total_pages ].min : page
    @parties = scope.limit(@per_page).offset((@page - 1) * @per_page).to_a
  end

  def show
    @tenancy_participations = @party.tenancy_parties
                                    .includes(tenancy: [ :property, :rentable_unit ])
                                    .order(effective_from: :desc, id: :desc)
  end

  def new
    @party = Party.new(party_type: "individual")
  end

  def edit
  end

  def create
    @party = authenticated_user.parties.new(party_params)

    respond_to do |format|
      if @party.save
        format.html { redirect_to @party, notice: "Party was successfully created." }
        format.json { render :show, status: :created, location: @party }
      else
        format.html { render :new, status: :unprocessable_content }
        format.json { render json: @party.errors, status: :unprocessable_content }
      end
    end
  end

  def update
    respond_to do |format|
      if @party.update(party_params)
        format.html { redirect_to @party, notice: "Party was successfully updated.", status: :see_other }
        format.json { render :show, status: :ok, location: @party }
      else
        format.html { render :edit, status: :unprocessable_content }
        format.json { render json: @party.errors, status: :unprocessable_content }
      end
    end
  end

  def destroy
    if @party.destroy
      respond_to do |format|
        format.html { redirect_to parties_path, notice: "Party was successfully destroyed.", status: :see_other }
        format.json { head :no_content }
      end
    else
      respond_to do |format|
        format.html { redirect_to @party, alert: @party.errors.full_messages.to_sentence, status: :see_other }
        format.json { render json: @party.errors, status: :unprocessable_content }
      end
    end
  end

  private

    def set_party
      @party = authenticated_user.parties.find(params.expect(:id))
    end

    def party_params
      params.require(:party).permit(
        :display_name,
        :party_type,
        :email_address,
        :phone_number,
        :mailing_address,
        party_aliases_attributes: %i[id alias_name _destroy]
      )
    end
end
