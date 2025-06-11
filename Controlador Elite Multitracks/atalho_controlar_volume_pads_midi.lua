--@description Controlar Volume PADs via MIDI
function FindPadsProjectSilent()
  local i=0; while true do local p,fn=reaper.EnumProjects(i,""); if not p then break end; if fn and fn:lower():match("pads%-elite") then return p end; i=i+1 end; return nil
end
local is_new,_,_,_,_,_,val=reaper.get_action_context()
if not is_new then return end
local vol_gain=val/127
local proj=FindPadsProjectSilent()
if proj then local master=reaper.GetMasterTrack(proj); if master then reaper.SetMediaTrackInfo_Value(master, "D_VOL", vol_gain) end end
reaper.defer(function() end)