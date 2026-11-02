// Sven Coop Hub - /tp <nombre>  (ir con un jugador)   /tp (lista jugadores)   /card (ver tu propia tarjeta)
// Al hacer /tp se le muestra a quien se teletransporta una tarjeta con el nombre y la skin de la otra persona.
void PluginInit()
{
	g_Module.ScriptInfo.SetAuthor( "Sven Coop Hub" );
	g_Module.ScriptInfo.SetContactInfo( "-" );
	g_Hooks.RegisterHook( Hooks::Player::ClientSay, @HubTpSay );
}

void MapInit()
{
	g_SoundSystem.PrecacheSound( "items/r_item1.wav" );
}

// Busca needle dentro de hay sin distinguir mayusculas
bool HubContains( const string& in hay, const string& in needle )
{
	uint n = needle.Length();
	uint h = hay.Length();
	if( n == 0 || n > h )
		return false;

	for( uint i = 0; i + n <= h; ++i )
	{
		bool ok = true;
		for( uint j = 0; j < n; ++j )
		{
			uint8 a = hay[ i + j ];
			uint8 b = needle[ j ];
			if( a >= 65 && a <= 90 )
				a += 32;
			if( b >= 65 && b <= 90 )
				b += 32;
			if( a != b )
			{
				ok = false;
				break;
			}
		}
		if( ok )
			return true;
	}
	return false;
}

CBasePlayer@ HubFindPlayer( CBasePlayer@ pMe, const string& in szQuery )
{
	CBasePlayer@ pPart = null;

	for( int i = 1; i <= g_Engine.maxClients; ++i )
	{
		CBasePlayer@ pOther = g_PlayerFuncs.FindPlayerByIndex( i );
		if( pOther is null || !pOther.IsConnected() || pOther is pMe )
			continue;

		string szName = "" + pOther.pev.netname;
		if( szName.Length() == szQuery.Length() && HubContains( szName, szQuery ) )
			return pOther;
		if( pPart is null && HubContains( szName, szQuery ) )
			@pPart = pOther;
	}
	return pPart;
}

string HubModelOf( CBasePlayer@ pPlayer )
{
	KeyValueBuffer@ pInfo = g_EngineFuncs.GetInfoKeyBuffer( pPlayer.edict() );
	return pInfo.GetValue( "model" );
}

// Tarjeta para pViewer con el nombre y la skin de pTarget:
//  - texto en el HUD del juego (lo ve cualquiera, sin instalar nada)
//  - una linea [HUBTP] en su consola, que el Hub (boton flotante) convierte en la tarjeta con la imagen de la skin
void HubAnnounce( CBasePlayer@ pViewer, CBasePlayer@ pTarget )
{
	string szName = "" + pTarget.pev.netname;
	string szModel = HubModelOf( pTarget );

	HUDTextParams tp;
	tp.x = -1;
	tp.y = 0.14;
	tp.effect = 0;
	tp.r1 = 255; tp.g1 = 168; tp.b1 = 38; tp.a1 = 255;
	tp.r2 = 255; tp.g2 = 168; tp.b2 = 38; tp.a2 = 255;
	tp.fadeinTime = 0.1;
	tp.fadeoutTime = 0.5;
	tp.holdTime = 3.5;
	tp.fxTime = 0.0;
	tp.channel = 3;
	g_PlayerFuncs.HudMessage( pViewer, tp, "TELETRANSPORTE\n" + szName + "\nskin: " + szModel );

	g_EngineFuncs.ClientPrintf( pViewer, print_console, "[HUBTP]|" + szName + "|" + szModel + "\n" );
}

HookReturnCode HubTpSay( SayParameters@ pParams )
{
	CBasePlayer@ pPlayer = pParams.GetPlayer();
	const CCommand@ pArguments = pParams.GetArguments();

	if( pArguments.ArgC() < 1 )
		return HOOK_CONTINUE;

	if( pArguments[ 0 ] == "/card" )
	{
		pParams.ShouldHide = true;
		HubAnnounce( pPlayer, pPlayer );
		return HOOK_HANDLED;
	}

	if( pArguments[ 0 ] != "/tp" )
		return HOOK_CONTINUE;

	pParams.ShouldHide = true;

	if( pPlayer.GetObserver().IsObserver() || !pPlayer.IsAlive() )
	{
		g_PlayerFuncs.ClientPrint( pPlayer, HUD_PRINTTALK, "[TP] No puedes teletransportarte estando muerto.\n" );
		return HOOK_HANDLED;
	}

	if( pArguments.ArgC() < 2 )
	{
		string szList = "[TP] Uso: /tp <nombre>. Jugadores: ";
		for( int i = 1; i <= g_Engine.maxClients; ++i )
		{
			CBasePlayer@ pOther = g_PlayerFuncs.FindPlayerByIndex( i );
			if( pOther is null || !pOther.IsConnected() || pOther is pPlayer )
				continue;
			szList += "" + pOther.pev.netname + "  ";
		}
		g_PlayerFuncs.ClientPrint( pPlayer, HUD_PRINTTALK, szList + "\n" );
		return HOOK_HANDLED;
	}

	string szQuery = pArguments[ 1 ];
	for( int i = 2; i < pArguments.ArgC(); ++i )
		szQuery += " " + pArguments[ i ];

	CBasePlayer@ pTarget = HubFindPlayer( pPlayer, szQuery );
	if( pTarget is null )
	{
		g_PlayerFuncs.ClientPrint( pPlayer, HUD_PRINTTALK, "[TP] No encontre a " + szQuery + ".\n" );
		return HOOK_HANDLED;
	}

	Vector vecDest = pTarget.pev.origin;
	vecDest.z += 4;
	pPlayer.SetOrigin( vecDest );
	pPlayer.pev.velocity = Vector( 0, 0, 0 );

	NetworkMessage message( MSG_BROADCAST, NetworkMessages::SVC_TEMPENTITY );
	message.WriteByte( TE_TELEPORT );
	message.WriteCoord( vecDest.x );
	message.WriteCoord( vecDest.y );
	message.WriteCoord( vecDest.z );
	message.End();
	g_SoundSystem.PlaySound( pPlayer.edict(), CHAN_STATIC, "items/r_item1.wav", 1.0f, 1.0f, 0, 100 );

	HubAnnounce( pPlayer, pTarget );
	return HOOK_HANDLED;
}
