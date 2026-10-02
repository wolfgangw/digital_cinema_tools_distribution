# frozen_string_literal: true

module DcpInspect
  module Inspection
    module Vocabulary
      Smpte_am = 'http://www.smpte-ra.org/schemas/429-9/2007/AM'
      Smpte_pkl = 'http://www.smpte-ra.org/schemas/429-8/2007/PKL'
      Smpte_cpl = 'http://www.smpte-ra.org/schemas/429-7/2006/CPL'
      Interop_am = 'http://www.digicine.com/PROTO-ASDCP-AM-20040311#'
      Interop_pkl = 'http://www.digicine.com/PROTO-ASDCP-PKL-20040311#'
      Interop_cpl = 'http://www.digicine.com/PROTO-ASDCP-CPL-20040511#'
      Composition_metadata_href = [
        'http://isdcf.com/schemas/draft/2011/cpl-metadata',
        'http://www.smpte-ra.org/schemas/429-16/2014/CPL-Metadata'
      ].freeze

      Ns_Xmldsig = 'http://www.w3.org/2000/09/xmldsig#'

      Schemas = {
        Smpte_am => 'SMPTE-429-9-2007-AM.xsd',
        Smpte_pkl => 'SMPTE-429-8-2006-PKL.xsd',
        Smpte_cpl => 'SMPTE-429-7-2006-CPL.xsd',
        Interop_am => 'PROTO-ASDCP-AM-20040311.xsd',
        Interop_pkl => 'PROTO-ASDCP-PKL-20040311.xsd',
        Interop_cpl => 'PROTO-ASDCP-CPL-20040511.xsd'
      }.freeze

      Stereoscopic_pictures = 'stereoscopic pictures'
      Pictures = 'pictures'
      Mpeg2 = 'MPEG2 video'
      Audio = 'audio'
      Atmos = 'Dolby ATMOS'
      Timed_text = 'timed text'
      Tkr_attr = 'x-TKR'

      AssetTypeSmpte = 'SMPTE'
      AssetTypeInterop = 'Interop'
      AssetTypeUnknown = 'Unknown'
      AssetTypeMixed = 'Mixed'
      AssetTypeUndetermined = 'Undetermined'

      TTF = 'Font TrueType'
      OTF = 'Font CFF-based'
      Cpl_content_kind_default_scope = 'http://www.smpte-ra.org/schemas/429-7/2006/CPL#standard-content'
      Cpl_standard_content = %w[feature trailer test teaser rating advertisement short transitional psa policy].freeze
      Cpl_standard_content_moniker_map = {
        ftr: :feature, tlr: :trailer, tst: :test, tsr: :teaser, rtg: :rating,
        pol: :policy, adv: :advertisement, shr: :short, xsn: :transitional, psa: :psa
      }.freeze

      Uuid_rfc4122_re = /^[0-9a-f]{8}-[0-9a-f]{4}-([1-5])[0-9a-f]{3}-[8-9a-b][0-9a-f]{3}-[0-9a-f]{12}$/i
      Uuid_re = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
      Uuid_particle_re = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i
    end
  end
end
