/*
 * mod-azeroth-vocations script registration entry point.
 * See docs/design/ for the design this module implements.
 */

void AddSC_av_classmaster_gossip();
void AddSC_av_commandscript();

void Addmod_azeroth_vocationsScripts()
{
    AddSC_av_classmaster_gossip();
    AddSC_av_commandscript();
}
