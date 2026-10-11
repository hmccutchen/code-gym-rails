module ScriptTextHelper
  # On <body>, the one element every page renders, signed in or out, so each page carries the text.
  def script_text_attributes
    tag.attributes(data: { signed_out_text: t("request.signed_out"), save_failed_text: t("save_status.generic") })
  end
end
