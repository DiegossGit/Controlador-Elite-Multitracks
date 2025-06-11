--@description PAINEL DE CONTROLE TOTAL
--@version 15.4.10 - Adiciona atalho para cancelar pulo de região.
--@about Painel de controle com feedback visual e controle de regiões com fade e loop.


local reaper = reaper

if not reaper.JS_Window_Find then
  reaper.ShowMessageBox("Para o docking automático, a extensão 'JS_ReaScriptAPI' é necessária.\n\nPor favor, instale-a via ReaPack.\nO script funcionará, mas a janela ficará flutuando.", "Extensão Necessária", 0)
end

local ctx = reaper.ImGui_CreateContext('Controlador Elite Multitracks')
if not ctx then
  reaper.ShowMessageBox("NÃO FOI POSSÍVEL CRIAR O CONTEXTO IMGUI. VERIFIQUE SE A EXTENSÃO SWS/S&M ESTÁ INSTALADA CORRETAMENTE.", "ERRO CRÍTICO", 0)
  return
end

local state = {
  pitch_value = 0,
  pad_volume = 0.8,
  auto_play_by_marker_enabled = false,
  follow_tonality_enabled = false
}
local project_pitch_states = {}
local last_active_project = nil
local last_tonality_project_name = ""
local last_known_tone = ""
local is_docked = false

local pending_region_jump = {
  active = false,
  target_index = -1,
  initial_play_region_index = -1
}

local STYLE_CONFIG = {
  FONT_NAME = "Impact",
  FONT_SIZE = 17,
  WINDOW_PADDING = { x = 25, y = 25 },
  ITEM_SPACING = { x = 12, y = 12 }
}

local font = reaper.ImGui_CreateFont(STYLE_CONFIG.FONT_NAME, STYLE_CONFIG.FONT_SIZE)
if not font then font = reaper.ImGui_CreateFont("Verdana", STYLE_CONFIG.FONT_SIZE - 1) end
if not font then font = reaper.ImGui_CreateFont("Arial", STYLE_CONFIG.FONT_SIZE - 1) end
reaper.ImGui_Attach(ctx, font)

local REGION_ABBREVIATIONS = {}
function GetRegionAbbreviation(name) local ln=name:lower(); return (REGION_ABBREVIATIONS[ln] or name:sub(1,4)):upper() end
local fade_next_active, fade_prev_active = false, false
local note_names = {'C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'}
local loop_cmd_id = 1068
local last_marker_pos, last_marker_name = nil, nil

function MonitorActionTriggers()
  local action_id = reaper.GetExtState("PainelControleTotal", "ActionFlag")
  if action_id and action_id ~= "" then
    reaper.SetExtState("PainelControleTotal", "ActionFlag", "", false)
    if action_id == "play_stop" then reaper.Main_OnCommand(40044, 0)
    elseif action_id == "loop" then ToggleLoopForCurrentRegion()
    elseif action_id == "prev_song" then StartFade("prev")
    elseif action_id == "next_song" then StartFade("next")
    elseif action_id == "auto_play" then state.auto_play_by_marker_enabled = not state.auto_play_by_marker_enabled
    elseif action_id == "pitch_plus" or action_id == "pitch_minus" then
      local amount = (action_id == "pitch_plus") and 1 or -1; local new_pitch = state.pitch_value + amount; new_pitch = math.max(-24, math.min(24, new_pitch))
      if new_pitch ~= state.pitch_value then NudgeItemsPitch(new_pitch - state.pitch_value); state.pitch_value = new_pitch; local proj = reaper.EnumProjects(-1, ""); if proj then project_pitch_states[proj] = new_pitch end end
    elseif action_id == "reset_pitch" then ResetAllPitch(); state.pitch_value = 0; local proj = reaper.EnumProjects(-1, ""); if proj then project_pitch_states[proj] = 0 end
    elseif action_id == "follow_tonality" then state.follow_tonality_enabled = not state.follow_tonality_enabled; if state.follow_tonality_enabled then TriggerCurrentProjectTonality() end
    elseif action_id == "stop_pads" then StopAllPads()
    -- [[ NOVO ATALHO ADICIONADO AQUI ]] --
    elseif action_id == "cancel_region_jump" then
      if pending_region_jump.active then
        GoToNextRegionAfterPlayhead()
        pending_region_jump.active = false
      end
    elseif action_id:match("pad_") then local note_to_toggle = action_id:gsub("pad_", ""):gsub("_sharp", "#"); TogglePadTrack(note_to_toggle) end
  end
end

function FindPadsProject()
  local i=0; while true do local p,fn=reaper.EnumProjects(i,""); if not p then break end; if fn and fn:lower():match("pads%-elite") then return p end; i=i+1 end
  if reaper.MB("Projeto 'PADs-Elite' não aberto.\n\nDeseja procurar e abrir agora?","Projeto de PADs não Encontrado",4)==6 then
    local r,fp=reaper.GetUserFileNameForRead("","Selecione 'PADs-Elite.rpp'","*.rpp"); if r and fp~="" then reaper.Main_openProject(fp); i=0; while true do local p,fn=reaper.EnumProjects(i,""); if not p then break end; if fn==fp then return p end; i=i+1 end end
  end
  return nil
end

function GetPadsProjectHandle() local i=0; while true do local p,fn=reaper.EnumProjects(i,""); if not p then break end; if fn and fn:lower():match("pads%-elite") then return p end; i=i+1 end; return nil end
function GetTrackByNameInProject(proj, name) if not proj then return nil end; for i=0,reaper.CountTracks(proj)-1 do local tr=reaper.GetTrack(proj,i); local _,n=reaper.GetSetMediaTrackInfo_String(tr,"P_NAME","",false); if n==name then return tr end end; return nil end
function IsProjectPlaying(proj) return proj and (reaper.GetPlayStateEx(proj) & 1) == 1 end
function PlayProject(proj) if proj and not IsProjectPlaying(proj) then reaper.Main_OnCommandEx(1007, 0, proj) end end
function StopProject(proj) if proj and IsProjectPlaying(proj) then reaper.Main_OnCommandEx(1016, 0, proj) end end
function FadeTrackVolume(track, target_vol, duration, on_done) if not track then if on_done then on_done() end; return end; local sv,st=reaper.GetMediaTrackInfo_Value(track,"D_VOL"),reaper.time_precise(); local function s() local t=math.min((reaper.time_precise()-st)/duration,1); reaper.SetMediaTrackInfo_Value(track,"D_VOL",sv+(target_vol-sv)*t); if t<1 then reaper.defer(s) else if on_done then on_done() end end end; s() end

function StopAllPads()
  state.follow_tonality_enabled = false
  local proj = GetPadsProjectHandle()
  if not proj then return end
  StopProject(proj)
  for i = 0, reaper.CountTracks(proj) - 1 do reaper.SetMediaTrackInfo_Value(reaper.GetTrack(proj, i), "D_VOL", 0.001) end
  reaper.SetExtState("PadToggle", "ActiveTrack", "", false)
end

function TogglePadTrack(note_name)
  local proj = FindPadsProject(); if not proj then return end
  local target_track = GetTrackByNameInProject(proj, note_name); if not target_track then reaper.MB("Track '"..note_name.."' não encontrada.","Erro",0); return end
  local last_active = reaper.GetExtState("PadToggle", "ActiveTrack")
  if last_active == note_name and not state.follow_tonality_enabled then
    reaper.SetExtState("PadToggle","ActiveTrack","",false); FadeTrackVolume(target_track,0.001,1.5,function() if reaper.GetExtState("PadToggle","ActiveTrack")=="" then StopProject(proj) end end)
  else
    reaper.SetExtState("PadToggle","ActiveTrack",note_name,false)
    for i=0,reaper.CountTracks(proj)-1 do local tr=reaper.GetTrack(proj,i); if tr~=target_track and reaper.GetMediaTrackInfo_Value(tr,"D_VOL") > 0.001 then FadeTrackVolume(tr,0.001,1.5) end end
    FadeTrackVolume(target_track, 1.0, 1.5); PlayProject(proj)
  end
end

function extract_tone(name) if not name then return nil end; return name:match("%((%u#?)%)") end
function TriggerCurrentProjectTonality() local _,pn=reaper.EnumProjects(-1,""); if pn then local t=extract_tone(pn); if t then TogglePadTrack(t); last_known_tone,last_tonality_project_name=t,pn end end end
function MonitorTonality() if not state.follow_tonality_enabled then return end; local _,pn=reaper.EnumProjects(-1,""); if pn and pn~=last_tonality_project_name then local t=extract_tone(pn); if t and t~=last_known_tone then TogglePadTrack(t); last_known_tone=t end; last_tonality_project_name=pn end end
function SyncPadVolumeFromProject() local pp=GetPadsProjectHandle(); if pp then local mt=reaper.GetMasterTrack(pp); if mt then local cv=reaper.GetMediaTrackInfo_Value(mt,"D_VOL"); if math.abs(state.pad_volume-cv)>0.001 then state.pad_volume=cv end end end end
function ReadCurrentPitchFromProject() local cit={[33554431]=true,[16777471]=true,[0]=true}; for i=0,reaper.CountTracks(0)-1 do local tr=reaper.GetTrack(0,i); local _,tn=reaper.GetTrackName(tr); if tn=="VOZ ENSAIO" or not cit[reaper.GetTrackColor(tr)] then for j=0,reaper.CountTrackMediaItems(tr)-1 do local tk=reaper.GetActiveTake(reaper.GetTrackMediaItem(tr,j)); if tk then return math.floor(reaper.GetMediaItemTakeInfo_Value(tk,"D_PITCH")+0.5) end end end end; return 0 end
function SyncPitchForCurrentProject() local cp=reaper.EnumProjects(-1,""); if not cp then return end; local ap=ReadCurrentPitchFromProject(); state.pitch_value=ap; project_pitch_states[cp]=ap end
function NudgeItemsPitch(diff) if diff==0 then return end; reaper.Undo_BeginBlock("Nudge Pitch",-1); local cit={[33554431]=true,[16777471]=true,[0]=true}; for i=0,reaper.CountTracks(0)-1 do local tr=reaper.GetTrack(0,i); local _,tn=reaper.GetTrackName(tr); if tn=="VOZ ENSAIO" or not cit[reaper.GetTrackColor(tr)] then for j=0,reaper.CountTrackMediaItems(tr)-1 do local tk=reaper.GetActiveTake(reaper.GetTrackMediaItem(tr,j)); if tk then reaper.SetMediaItemTakeInfo_Value(tk,"D_PITCH",reaper.GetMediaItemTakeInfo_Value(tk,"D_PITCH")+diff) end end end end; reaper.UpdateArrange(); reaper.Undo_EndBlock("Nudge Pitch",-1) end
function ResetAllPitch() reaper.Undo_BeginBlock("Reset Pitch",-1); for i=0,reaper.CountTracks(0)-1 do for j=0,reaper.CountTrackMediaItems(reaper.GetTrack(0,i))-1 do local tk=reaper.GetActiveTake(reaper.GetTrackMediaItem(reaper.GetTrack(0,i),j)); if tk then reaper.SetMediaItemTakeInfo_Value(tk,"D_PITCH",0) end end end; reaper.UpdateArrange(); reaper.Undo_EndBlock("Reset Pitch",-1) end
function MonitorAutoPlay() if not state.auto_play_by_marker_enabled or reaper.GetPlayState()&1==0 or fade_next_active or fade_prev_active then return end; local pp=reaper.GetPlayPosition(); local _,nm,nr=reaper.CountProjectMarkers(0); for i=0,nm+nr-1 do local r,ir,sp,_,n=reaper.EnumProjectMarkers3(0,i); if r and not ir and math.abs(pp-sp)<=0.2 and (last_marker_pos~=sp or last_marker_name~=n) then last_marker_pos,last_marker_name=sp,n; local nu=n:upper(); if nu:find("NEXT") then StartFade("next"); return elseif nu:find("PREV") then StartFade("prev"); return end end end end
function SetLoopToCurrentRegion() local p=reaper.GetPlayPosition(); local _,nm,nr=reaper.CountProjectMarkers(0); for i=0,nm+nr-1 do local rv,ir,sp,ep=reaper.EnumProjectMarkers3(0,i); if rv and ir and p>=sp and p<=ep then reaper.GetSet_LoopTimeRange(true,false,sp,ep,false); return true end end; return false end
function ToggleLoopForCurrentRegion() if reaper.GetToggleCommandState(loop_cmd_id)==1 then reaper.GetSet_LoopTimeRange(true,false,0,0,false); reaper.Main_OnCommand(loop_cmd_id,0) else if SetLoopToCurrentRegion() then reaper.Main_OnCommand(loop_cmd_id,0) else reaper.MB("Nenhuma região encontrada.","Aviso",0) end end end
function StartFade(d) if(d=="next" and fade_next_active)or(d=="prev" and fade_prev_active)then return end; local p=reaper.EnumProjects(-1,""); if not p then return end; local m=reaper.GetMasterTrack(p); local wp=reaper.GetPlayState()&1==1; local sv=reaper.GetMediaTrackInfo_Value(m,"D_VOL"); if d=="next" then fade_next_active=true else fade_prev_active=true end; FadeTrackVolume(m,0,0.5,function() if wp then reaper.Main_OnCommand(40044,0) end; reaper.Main_OnCommand(d=="next" and 40861 or 40862,0); reaper.defer(function() local np=reaper.EnumProjects(-1,""); if np then local nm=reaper.GetMasterTrack(np); reaper.SetMediaTrackInfo_Value(nm,"D_VOL",sv); if wp then reaper.Main_OnCommand(40044,0) end end; if d=="next" then fade_next_active=false else fade_prev_active=false end end) end) end

function GoToNextRegionAfterPlayhead()
  local play_pos = reaper.GetPlayPosition(); local next_region_pos = -1; local min_start_time = math.huge
  local proj = reaper.EnumProjects(-1); if not proj then return end
  local _, num_markers, num_regions = reaper.CountProjectMarkers(0)
  for i = 0, num_markers + num_regions - 1 do
    local retval, is_region, pos = reaper.EnumProjectMarkers3(proj, i)
    if retval and is_region and pos > play_pos and pos < min_start_time then min_start_time, next_region_pos = pos, pos end
  end
  if next_region_pos ~= -1 then reaper.SetEditCurPos(next_region_pos, true, true) end
end

function MonitorPendingRegionJump(current_play_region_index)
  if not pending_region_jump.active then return end
  if current_play_region_index ~= -1 and current_play_region_index ~= pending_region_jump.initial_play_region_index then
    pending_region_jump.active = false
  end
end

function GetCurrentPlayRegionIndex()
  local play_pos = reaper.GetPlayPosition(); local proj = reaper.EnumProjects(-1); if not proj then return -1 end
  local _, num_markers, num_regions = reaper.CountProjectMarkers(0)
  for i = 0, num_markers + num_regions - 1 do
    local retval, is_region, pos, region_end, _, region_idx = reaper.EnumProjectMarkers3(proj, i)
    if retval and is_region and play_pos >= pos and play_pos < region_end then return region_idx end
  end
  return -1
end

function DrawPlaybackController()
  reaper.ImGui_BeginGroup(ctx); if reaper.ImGui_Button(ctx,'PLAY/STOP',140,45) then reaper.Main_OnCommand(40044,0) end; reaper.ImGui_SameLine(ctx)
  local lwa=reaper.GetToggleCommandState(loop_cmd_id)==1; if lwa then reaper.ImGui_PushStyleColor(ctx,reaper.ImGui_Col_Button(),0x00FF00FF) end; if reaper.ImGui_Button(ctx,'LOOP',140,45) then ToggleLoopForCurrentRegion() end; if lwa then reaper.ImGui_PopStyleColor(ctx) end
  local pwf=fade_prev_active; if pwf then reaper.ImGui_PushStyleColor(ctx,reaper.ImGui_Col_Button(),0x00FF00FF) end; if reaper.ImGui_Button(ctx,'PREV SONG',140,45) then StartFade("prev") end; if pwf then reaper.ImGui_PopStyleColor(ctx) end; reaper.ImGui_SameLine(ctx)
  local nwf=fade_next_active; if nwf then reaper.ImGui_PushStyleColor(ctx,reaper.ImGui_Col_Button(),0x00FF00FF) end; if reaper.ImGui_Button(ctx,'NEXT SONG',140,45) then StartFade("next") end; if nwf then reaper.ImGui_PopStyleColor(ctx) end
  local apwe=state.auto_play_by_marker_enabled; if apwe then reaper.ImGui_PushStyleColor(ctx,reaper.ImGui_Col_Button(),0x00FF00FF) end; if reaper.ImGui_Button(ctx,"AUTO PLAY: "..(apwe and "ON" or "OFF"),292,40) then state.auto_play_by_marker_enabled=not state.auto_play_by_marker_enabled end; if apwe then reaper.ImGui_PopStyleColor(ctx) end
  reaper.ImGui_Text(ctx,"PITCH"); reaper.ImGui_SameLine(ctx); reaper.ImGui_PushItemWidth(ctx,212); local ch,nv=reaper.ImGui_InputInt(ctx,"##pitch",state.pitch_value,1,12); if ch then nv=math.max(-24,math.min(24,nv)); if nv~=state.pitch_value then NudgeItemsPitch(nv-state.pitch_value); state.pitch_value=nv; local p=reaper.EnumProjects(-1,""); if p then project_pitch_states[p]=nv end end end; reaper.ImGui_PopItemWidth(ctx); reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx,"R",23,23) then ResetAllPitch(); state.pitch_value=0; local p=reaper.EnumProjects(-1,""); if p then project_pitch_states[p]=0 end end; reaper.ImGui_EndGroup(ctx)
end

function DrawPadPlayer()
  reaper.ImGui_BeginGroup(ctx); reaper.ImGui_BeginGroup(ctx)
  local apn=reaper.GetExtState("PadToggle","ActiveTrack"); for i,n in ipairs(note_names) do local pwa=(apn==n); if pwa then reaper.ImGui_PushStyleColor(ctx,reaper.ImGui_Col_Button(),0x00FF00FF) end; if reaper.ImGui_Button(ctx,n,80,50) then TogglePadTrack(n) end; if pwa then reaper.ImGui_PopStyleColor(ctx) end; if i%4~=0 then reaper.ImGui_SameLine(ctx) end end
  local fwe=state.follow_tonality_enabled; if fwe then reaper.ImGui_PushStyleColor(ctx,reaper.ImGui_Col_Button(),0x00FF00FF) end; if reaper.ImGui_Button(ctx,"SEGUIR TONALIDADE",(80*4)+(STYLE_CONFIG.ITEM_SPACING.x*3),40) then state.follow_tonality_enabled=not state.follow_tonality_enabled; if state.follow_tonality_enabled then TriggerCurrentProjectTonality() end end; if fwe then reaper.ImGui_PopStyleColor(ctx) end
  local sbw=(80*4)+(STYLE_CONFIG.ITEM_SPACING.x*3); reaper.ImGui_PushStyleColor(ctx,reaper.ImGui_Col_Button(),0xFF0000FF); reaper.ImGui_PushStyleColor(ctx,reaper.ImGui_Col_Text(),0xFFFFFFFF); if reaper.ImGui_Button(ctx,"STOP PADS",sbw,40) then StopAllPads() end; reaper.ImGui_PopStyleColor(ctx,2)
  reaper.ImGui_EndGroup(ctx); reaper.ImGui_SameLine(ctx,0,STYLE_CONFIG.ITEM_SPACING.x+10); reaper.ImGui_BeginGroup(ctx); reaper.ImGui_Text(ctx,"PAD")
  local vi=math.floor(state.pad_volume*100+0.5); if vi>100 then vi=100 end; local ch,nvi=reaper.ImGui_VSliderInt(ctx,"##pad_vol",40,160,vi,0,100); if ch then state.pad_volume=nvi/100; local pp=GetPadsProjectHandle(); if pp then local m=reaper.GetMasterTrack(pp); if m then reaper.SetMediaTrackInfo_Value(m,"D_VOL",state.pad_volume) end end end
  reaper.ImGui_EndGroup(ctx); reaper.ImGui_EndGroup(ctx)
end

function DrawRegionsSection(current_play_region_index)
  reaper.ImGui_BeginGroup(ctx)
  local proj = reaper.EnumProjects(-1)
  if not proj then reaper.ImGui_Text(ctx, "NENHUM PROJETO ATIVO.") else
    local _, num_markers, num_regions = reaper.CountProjectMarkers(0)
    if num_regions == 0 then reaper.ImGui_Text(ctx, "NENHUMA REGIÃO ENCONTRADA.") else
      local buttons_in_row = 0
      for i = 0, num_markers + num_regions - 1 do
        local retval, is_region, pos, region_end, name, region_idx, color = reaper.EnumProjectMarkers3(proj, i)
        if retval and is_region then
          if buttons_in_row > 0 then reaper.ImGui_SameLine(ctx) end
          buttons_in_row = buttons_in_row + 1
          local is_pending_target = (pending_region_jump.active and pending_region_jump.target_index == region_idx)
          local is_playing = (current_play_region_index ~= -1 and current_play_region_index == region_idx)
          local w, h = (is_playing or is_pending_target) and 120 or 60, (is_playing or is_pending_target) and 90 or 45
          local has_color = color ~= 0 and color ~= nil
          if has_color then local r,g,b=reaper.ColorFromNative(color); reaper.ImGui_PushStyleColor(ctx,reaper.ImGui_Col_Button(),(r*0x1000000)+(g*0x10000)+(b*0x100)+0xFF); reaper.ImGui_PushStyleColor(ctx,reaper.ImGui_Col_Text(),0x000000FF) end
          local button_text = GetRegionAbbreviation(name)
          if is_pending_target then button_text = "CANCELAR" end
          if reaper.ImGui_Button(ctx, button_text .. "##" .. i, w, h) then
            if is_pending_target then
              GoToNextRegionAfterPlayhead(); pending_region_jump.active = false
            else
              reaper.SetEditCurPos(pos, true, true)
              pending_region_jump.active = true
              pending_region_jump.target_index = region_idx
              pending_region_jump.initial_play_region_index = current_play_region_index
            end
          end
          if has_color then reaper.ImGui_PopStyleColor(ctx, 2) end
          if buttons_in_row >= 12 then buttons_in_row = 0 end
        end
      end
    end
  end
  reaper.ImGui_EndGroup(ctx)
end

function main()
  MonitorActionTriggers()
  local current_proj = reaper.EnumProjects(-1, "")
  if current_proj ~= last_active_project then SyncPitchForCurrentProject(); last_active_project = current_proj end
  MonitorAutoPlay(); MonitorTonality(); SyncPadVolumeFromProject()
  local current_play_region_index = GetCurrentPlayRegionIndex()
  MonitorPendingRegionJump(current_play_region_index)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), STYLE_CONFIG.WINDOW_PADDING.x, STYLE_CONFIG.WINDOW_PADDING.y)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), STYLE_CONFIG.ITEM_SPACING.x, STYLE_CONFIG.ITEM_SPACING.y)
  reaper.ImGui_SetNextWindowSize(ctx, 1750, 310, reaper.ImGui_Cond_FirstUseEver())
  local window_title = 'PAINEL DE CONTROLE TOTAL'
  local visible, open = reaper.ImGui_Begin(ctx, window_title, true)
  if not is_docked and visible and reaper.JS_Window_Find then local hwnd = reaper.JS_Window_Find(window_title, true); if hwnd then reaper.DockWindowAdd(hwnd, window_title, 3, true); is_docked = true end end
  
  if visible then
    reaper.ImGui_PushFont(ctx, font)
    DrawPlaybackController(); reaper.ImGui_SameLine(ctx, 0, STYLE_CONFIG.ITEM_SPACING.x * 6)
    DrawPadPlayer(); reaper.ImGui_SameLine(ctx, 0, STYLE_CONFIG.ITEM_SPACING.x * 6)
    DrawRegionsSection(current_play_region_index)
    reaper.ImGui_PopFont(ctx); reaper.ImGui_End(ctx)
  end
  
  reaper.ImGui_PopStyleVar(ctx, 2)
  if open then reaper.defer(main) else reaper.ImGui_DestroyContext(ctx) end
end

reaper.defer(main)
