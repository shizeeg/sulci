(*                                                                          *)
(* (c) 2004, 2005 Anastasia Gornostaeva. <ermine@ermine.pp.ru>              *)
(*                                                                          *)

open Common
open Muc
open Xmpp
open Xml
open Sqlite
open Sqlite_util
open Hooks
open Types

let length s = Netconversion.ustring_length `Enc_utf8 s

let split_words text =
   Pcre.split ~pat:"[ \t\n]+" text

let db =
   let file = 
      try trim (Xml.get_attr_s Config.config 
		   ~path:["plugins"; "talkers"] "db")
      with Not_found -> "talkers.db" in
   let db = Sqlite.db_open file in
      if not (result_bool db
	 "SELECT name FROM SQLITE_MASTER WHERE type='table' AND name='talkers'")
      then begin try
	 exec db
	    "CREATE TABLE talkers (jid varchar, nick varchar, room varchar, words int, me int, sentences int)";
	 exec db "create index talkersidx on talkers(jid, room)";
	 exec db "create index words_idx on talkers(words)"
      with Sqlite_error s -> 
	 raise (Failure "error while creating table")
      end;
      db

let talkers event from xml out =
   match event with
      | MUC_message (msg_type, nick, text) ->
	   if msg_type = `Groupchat then
	      let room = from.luser, from.lserver in
	      let room_s = from.luser ^ "@" ^ from.lserver in
		 if text <> "" then
		    let room_env = GroupchatMap.find room !groupchats in
		       if from.lresource <> room_env.mynick then
			  let words = string_of_int 
			     (List.length (split_words text)) in
			  let me = 
			     if nick = "" && 
				((length text = 3 && text = "/me") ||
				    (length text > 3 && 
					String.sub text 0 4 = "/me ")) 
			     then
				"1" else "0" in
			  let jid = (Nicks.find from.lresource 
					room_env.nicks).jid in
			  let cond =
			     match jid with
				| None -> "nick=" ^ escape from.lresource
				| Some j -> "jid=" ^ escape (j.luser ^ "@" ^
								j.lserver)
			  in
			     if result_bool db
				("SELECT words FROM talkers WHERE " ^ cond ^
				    " AND room=" ^ escape room_s) then
				   exec db 
				      ("UPDATE talkers SET words=words+" ^ 
					  words ^
					", sentences=sentences+1, me=me+" ^ me ^
					  " WHERE " ^ cond ^
					  " AND room=" ^ escape room_s)
			     else
				exec db ("INSERT INTO talkers " ^ values 
					    [escape (match jid with
							| None -> ""
							| Some j -> j.luser ^
							     "@" ^ j.lserver);
					     escape from.resource; 
					     escape room_s; words; me; "1"])
      | _ -> ()

let cmd_talkers text event from xml out =
   match event with
      | MUC_message (msg_type, _, _) ->
	   let room = from.luser, from.lserver in
	   let room_s = from.luser ^ "@" ^ from.lserver in
	   let nick = Stringprep.resourceprep text in
	   let vm = compile_simple db
	      ("SELECT nick, words, me, sentences FROM talkers WHERE room=" ^
		  escape room_s ^ 
		  (if text = "" then 
		      " ORDER BY words DESC, sentences ASC  LIMIT 10" 
		   else " AND nick like " ^ escape nick ^ 
		      " ORDER BY words DESC, sentences ASC")) in
	   let rec cycle () =
	      try
		 let result = step_simple vm in
		    result :: cycle ()
	      with Sqlite_done -> []
	   in
	   let header = Array.of_list [
	      Lang.get_msg ~xml "plugin_talkers_top_header_man" [];
	      Lang.get_msg ~xml "plugin_talkers_top_header_words" [];
	      Lang.get_msg ~xml "plugin_talkers_top_header_actions" [];
	      Lang.get_msg ~xml "plugin_talkers_top_header_sentences" [];
	      Lang.get_msg ~xml "plugin_talkers_top_header_average" []]
	   in
	   let data = cycle () in
	   let max_len =
	      let rec cycle max l =
		 match l with
		    | [] -> max
		    | h :: t -> 
			 if length h.(0) > max then
			    cycle (length h.(0)) t
			 else
			    cycle max t
	      in
		 cycle (length header.(0) / 8) data in
	   let tabs = max_len / 8 + 1 in
	   let tab = String.make tabs '\t' in
	   let rec cycle l acc =
	      match l with
		 | [] -> String.concat "" (List.rev acc)
		 | h :: t ->
		      let m = tabs - (length h.(0) / 8) in
			 cycle t ((Printf.sprintf "%s%s%s\t%s\t%s\t%.2g\n"
			     h.(0) 
			     (String.sub tab 0 m)
			     h.(1) h.(2) h.(3) 
			     (float_of_string h.(1) /. float_of_string h.(3))
			 ) :: acc)
	   in
	   let r = cycle data [] in
	      if r <> "" then
		 out (make_msg xml 
			 ((Printf.sprintf "\n%s%s%s\t%s\t%s\t%s\n"
			      header.(0)
			      (String.sub tab 0 (tabs - (length header.(0)/8)))
			      header.(1) header.(2) header.(3) header.(4)) ^ 
			     r))
	      else
		 out (make_msg xml
			 (Lang.get_msg ~xml "plugin_talkers_no_result" []))
      | _ -> ()
		 
let _ =
   Hooks.register_handle (Catch talkers);
   Hooks.register_handle (Command ("talkers", cmd_talkers))
