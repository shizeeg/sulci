(*                                                                          *)
(* (c) 2004, 2005 Anastasia Gornostaeva. <ermine@ermine.pp.ru>              *)
(*                                                                          *)

open Xml
open Xmpp
open Common
open Http_suck

(* 
   doGoogleSearch method
   "key"        (google account)
   "q"          (query text),
   "start"      (where to start returning in the results),
   "maxResults" (number of allowed results),
   "filter"     (filter out very similar results),
   "restrict"   (country or topic restrictions),
   "safeSearch" (pornography filter), 
   "lr"         (language restrict), 
   "ie"         (input encoding)
   "oe"         (output encoding). 
*)

let google_key = trim (Xml.get_cdata Config.config 
			  ~path:["plugins"; "google"; "key"])

let make_query start maxResults query =
   let filter = "true" in
   Xmlelement
      ("SOAP-ENV:Envelope",
       ["xmlns:SOAP-ENV", "http://schemas.xmlsoap.org/soap/envelope/";
	"xmlns:xsi", "http://www.w3.org/1999/XMLSchema-instance";
	"xmlns:xsd", "http://www.w3.org/1999/XMLSchema"],
       [Xmlelement 
	   ("SOAP-ENV:Body", [], 
	    [Xmlelement ("ns1:doGoogleSearch",
			 ["xmlns:ns1", "urn:GoogleSearch";
			  "SOAP-ENV:encodingStyle",
			  "http://schemas.xmlsoap.org/soap/encoding/"],
			 [Xmlelement ("key", 
				      ["xsi:type", "xsd:string"], 
				      [Xmlcdata google_key]);
			  Xmlelement ("q", 
				      ["xsi:type", "xsd:string"],
				      [Xmlcdata query]);
			  Xmlelement ("start",
				      ["xsi:type", "xsd:int"], 
				      [Xmlcdata start]);
			  Xmlelement ("maxResults",
				      ["xsi:type", "xsd:int"],
				      [Xmlcdata maxResults]);
			  Xmlelement ("filter",
				      ["xsi:type", "xsd:boolean"],
				      [Xmlcdata filter]);
			  Xmlelement ("restrict",
				      ["xsi:type", "xsd:string"], 
				      []);
			  Xmlelement ("safeSearch", 
				      ["xsi:type", "xsd:boolean"],
				      [Xmlcdata "false"]);
			  Xmlelement ("lr",
				      ["xsi:type", "xsd:string"], 
				      []);
			 (* [Xmlcdata "lang_ru"]; *)
			  Xmlelement ("ie",
				      ["xsi:type", "xsd:string"],
				      []);
			  Xmlelement ("oe", 
				      ["xsi:type", "xsd:string"],
				      [])
			 ])])])

let html_ent = Pcre.regexp "&amp;#([0-9]+);"
let html = Pcre.regexp "&lt;/?(b|i|p|br)&gt;"
let amp = Pcre.regexp "&amp;(lt|gt|quot|apos|amp);"

let strip_html text =
   let r1 = Pcre.qreplace ~rex:html ~templ:"" text in
   let r2 = 
      Pcre.substitute_substrings ~rex:html_ent
	 ~subst:(fun x ->
		    let p = Pcre.get_substring x 1 in
		    let newstr = String.create 1 in
		       newstr.[0] <- Char.chr (int_of_string p);
		       newstr) r1 in
   let r3 = Pcre.substitute_substrings ~rex:amp
	       ~subst:(fun x -> "&" ^ (Pcre.get_substring x 1) ^ ";") r2
   in r3

let message result =
   let text item tag = strip_html (get_cdata item ~path:[tag]) in
   let rec cycle lst acc = 
      if lst = [] then acc
      else
	 let item = List.hd lst in
	 let chunked = match item with
	    | Xmlelement (_, _, _) ->
		 Printf.sprintf "%s%s%s%s - %s"
		    (let t = text item "title" in
			if t = "" then "" else t ^ "\n")
		    (let t = text item "summary" in
			if t = "" then "" else t ^ "\n")
		    (let t = text item "snippet" in
			if t = "" then "" else t ^ "\n")
		    (get_cdata item ~path:["URL"])
		    (text item "cachedSize");
	    | _ -> ""
	 in
	    cycle (List.tl lst) (acc ^ chunked)
   in
      cycle (get_subels result) ""

let xmldecl = "<?xml version='1.0' encoding='UTF-8' ?>\r\n"

let gspell text event from xml out =
   if text = "" then
      out (make_msg xml 
	      (Lang.get_msg ~xml "plugin_google_invalid_syntax" []))
   else
      let soap = 
	 Xmlelement 
	    ("SOAP-ENV:Envelope", 
	     ["xmlns:SOAP-ENV","http://schemas.xmlsoap.org/soap/envelope/";
	      "xmlns:xsi", "http://www.w3.org/1999/XMLSchema-instance";
	      "xmlns:xsd", "http://www.w3.org/1999/XMLSchema"],
	     [Xmlelement ("SOAP-ENV:Body", [],
			  [Xmlelement 
			      ("ns1:doSpellingSuggestion", 
			       ["xmlns:ns1", "urn:GoogleSearch";
				"SOAP-ENV:encodingStyle", 
				"http://schemas.xmlsoap.org/soap/encoding/"],
			       [Xmlelement ("key", ["xsi:type", "xsd:string"],
					    [Xmlcdata google_key]);
				Xmlelement ("phrase", 
					    ["xsi:type", "xsd:string"],
					    [Xmlcdata text])
			       ])])]) in
      let query = element_to_string soap in
      let callback data =
	 let resp = match data with
	    | OK content ->
		 let parsed = Xmlstring.parse_string content in
		 let response = 
		    Xml.get_cdata parsed 
		       ~path:["SOAP-ENV:Body"; 
			      "ns1:doSpellingSuggestionResponse";
			      "return"] in
		    if response = "" then 
		       "[нет ответа]" 
		    else response
	    | Exception exn ->
		 match exn with
		    | ClientError -> "not found"
		    | ServerError -> "server broken"
		    | _ -> "some problems"
	 in
	    out (make_msg xml resp)
      in
	 Http_suck.http_post "http://api.google.com/search/beta2"
	    ["Content-Type", "text/xml; charset=utf-8"] 
	    (xmldecl ^ query) callback
	    
let google ?(start="0") ?(items="1") text event from xml out =
   if text = "" then
      out (make_msg xml 
	      (Lang.get_msg ~xml "plugin_google_invalid_syntax" []))
   else
      let callback data =
	 let resp = match data with
	    | OK content ->
		 let parsed = Xmlstring.parse_string content in
		 let result = Xml.get_tag parsed ["SOAP-ENV:Body"; 
						  "ns1:doGoogleSearchResponse";
						  "return";
						  "resultElements"] 
		 in
		 let r = message result in
		    if r = "" then
		       Lang.get_msg ~xml "plugin_google_not_found" []
		    else r
	    | Exception exn ->
		 match exn with
		    | ClientError -> "not found"
		    | ServerError -> "server broken"
		    | _ -> "some problems"
	 in
	    out (make_msg xml resp)
      in
      let soap = make_query start items text in
	 Http_suck.http_post "http://api.google.com/search/beta2"
	    ["Accept-Encoding", "identity";
	     "SOAPAction", "urn:GoogleSearchAction";
	     "Content-Type", "text/xml; charset=utf-8"]
	    (xmldecl ^ element_to_string soap)
	    callback

let rx = Pcre.regexp "([0-9]+) ([1-9]{1}) (.+)"

let google_adv text event from xml out =
   try
      let r = Pcre.exec ~rex:rx text in
      let start = Pcre.get_substring r 1 in
      let items = Pcre.get_substring r 2 in
      let request = Pcre.get_substring r 3 in
	 google ~start ~items request event from xml out
   with Not_found ->
      out (make_msg xml 
	      (Lang.get_msg ~xml "plugin_google_adv_invalid_syntax" []))

let _ =
   Hooks.register_handle (Hooks.Command ("google", google));
   Hooks.register_handle (Hooks.Command ("google_adv", google_adv));
   Hooks.register_handle (Hooks.Command ("gspell", gspell))
