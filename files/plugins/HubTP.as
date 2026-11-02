// Sven Coop Hub - comandos de chat
//   Para todos:      /tp <nombre>   /card   /kill   /ayuda        (y /s /p del plugin Teleport)
//   Solo anfitrion:  /god  /noclip  /notarget  /armas  /give <arma>  /restart  /map <mapa>
//                    /gravedad baja|normal  /velocidad rapida|normal  /respawn <seg>
// Al hacer /tp se le muestra a quien se teletransporta una tarjeta con el nombre y la skin de la otra persona.
void PluginInit()
{
	g_Module.ScriptInfo.SetAuthor( "Sven Coop Hub" );
	g_Module.ScriptInfo.SetContactInfo( "-" );
	g_Hooks.RegisterHook( Hooks::Player::ClientSay, @HubOnSay );
}

void MapInit()
{
	g_SoundSystem.PrecacheSound( "items/r_item1.wav" );
}

// ---------------------------------------------------------------- utilidades

void HubSay( CBasePlayer@ pPlayer, const string& in szText )
{
	g_PlayerFuncs.ClientPrint( pPlayer, HUD_PRINTTALK, "[Hub] " + szText + "\n" );
}

bool HubIsHost( CBasePlayer@ pPlayer )
{
	return g_PlayerFuncs.AdminLevel( pPlayer ) >= ADMIN_YES;
}

// Solo letras, numeros, _ y - (evita meter comandos de servidor dentro de un argumento)
bool HubSafeToken( const string& in s )
{
	if( s.Length() == 0 || s.Length() > 40 )
		return false;
	for( uint i = 0; i < s.Length(); ++i )
	{
		uint8 c = s[ i ];
		bool ok = ( c >= 48 && c <= 57 ) || ( c >= 65 && c <= 90 ) || ( c >= 97 && c <= 122 ) || c == 95 || c == 45;
		if( !ok )
			return false;
	}
	return true;
}

// Entero de 0 a 999 desde texto; -1 si no es un numero
int HubParseInt( const string& in s )
{
	if( s.Length() == 0 || s.Length() > 3 )
		return -1;
	int v = 0;
	for( uint i = 0; i < s.Length(); ++i )
	{
		uint8 c = s[ i ];
		if( c < 48 || c > 57 )
			return -1;
		v = v * 10 + ( c - 48 );
	}
	return v;
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

// "shotgun", "weapon_shotgun", "botiquin"... -> nombre de entidad, o "" si no esta en la lista
string HubItemName( const string& in szWhat )
{
	array<string> names = {
		"weapon_crowbar", "weapon_9mmhandgun", "weapon_357", "weapon_9mmAR", "weapon_shotgun", "weapon_crossbow",
		"weapon_rpg", "weapon_gauss", "weapon_egon", "weapon_hornetgun", "weapon_handgrenade", "weapon_satchel",
		"weapon_tripmine", "weapon_snark", "item_healthkit", "item_battery", "item_longjump" };
	array<string> alias = {
		"crowbar", "pistola", "magnum", "mp5", "escopeta", "ballesta",
		"rpg", "gauss", "egon", "hornet", "granadas", "satchel",
		"tripmine", "snarks", "botiquin", "bateria", "saltolargo" };

	for( uint i = 0; i < names.length(); ++i )
	{
		if( HubContains( names[ i ], szWhat ) && szWhat.Length() >= 3 && names[ i ].Length() - szWhat.Length() <= 7 )
			return names[ i ];
		if( alias[ i ] == szWhat )
			return names[ i ];
	}
	return "";
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

// ---------------------------------------------------------------- comandos

void HubTeleport( CBasePlayer@ pPlayer, const CCommand@ pArguments )
{
	if( pPlayer.GetObserver().IsObserver() || !pPlayer.IsAlive() )
	{
		HubSay( pPlayer, "No puedes teletransportarte estando muerto." );
		return;
	}

	if( pArguments.ArgC() < 2 )
	{
		string szList = "Uso: /tp <nombre>. Jugadores: ";
		for( int i = 1; i <= g_Engine.maxClients; ++i )
		{
			CBasePlayer@ pOther = g_PlayerFuncs.FindPlayerByIndex( i );
			if( pOther is null || !pOther.IsConnected() || pOther is pPlayer )
				continue;
			szList += "" + pOther.pev.netname + "  ";
		}
		HubSay( pPlayer, szList );
		return;
	}

	string szQuery = pArguments[ 1 ];
	for( int i = 2; i < pArguments.ArgC(); ++i )
		szQuery += " " + pArguments[ i ];

	CBasePlayer@ pTarget = HubFindPlayer( pPlayer, szQuery );
	if( pTarget is null )
	{
		HubSay( pPlayer, "No encontre a " + szQuery + "." );
		return;
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
}

void HubHelp( CBasePlayer@ pPlayer )
{
	HubSay( pPlayer, "Todos: /tp <nombre>  /card  /kill  /s  /p" );
	if( HubIsHost( pPlayer ) )
		HubSay( pPlayer, "Anfitrion: /god /noclip /notarget /armas /give <arma> /restart /map <mapa> /gravedad baja|normal /velocidad rapida|normal /respawn <seg>" );
	else
		HubSay( pPlayer, "Los demas comandos son solo del anfitrion." );
}

void HubToggleFlag( CBasePlayer@ pPlayer, int iFlag, const string& in szLabel )
{
	pPlayer.pev.flags = pPlayer.pev.flags ^ iFlag;
	bool on = ( pPlayer.pev.flags & iFlag ) != 0;
	HubSay( pPlayer, szLabel + ( on ? " activado" : " desactivado" ) );
}

// Devuelve true si el comando era de este plugin
bool HubHandle( CBasePlayer@ pPlayer, const CCommand@ pArguments )
{
	string szCmd = pArguments[ 0 ];

	// ----- para todos
	if( szCmd == "/tp" )     { HubTeleport( pPlayer, pArguments ); return true; }
	if( szCmd == "/card" )   { HubAnnounce( pPlayer, pPlayer ); return true; }
	if( szCmd == "/ayuda" || szCmd == "/help" ) { HubHelp( pPlayer ); return true; }
	if( szCmd == "/kill" )
	{
		if( pPlayer.IsAlive() )
			pPlayer.TakeDamage( pPlayer.pev, pPlayer.pev, 10000, DMG_GENERIC );
		return true;
	}

	// ----- solo anfitrion
	bool bAdminCmd = szCmd == "/god" || szCmd == "/noclip" || szCmd == "/notarget" || szCmd == "/armas" || szCmd == "/give" || szCmd == "/dar"
		|| szCmd == "/restart" || szCmd == "/reiniciar" || szCmd == "/map" || szCmd == "/mapa" || szCmd == "/gravedad" || szCmd == "/velocidad" || szCmd == "/respawn";
	if( !bAdminCmd )
		return false;

	if( !HubIsHost( pPlayer ) )
	{
		HubSay( pPlayer, szCmd + " es solo del anfitrion." );
		return true;
	}

	if( szCmd == "/god" )      { HubToggleFlag( pPlayer, FL_GODMODE, "God" ); return true; }
	if( szCmd == "/notarget" ) { HubToggleFlag( pPlayer, FL_NOTARGET, "Notarget" ); return true; }
	if( szCmd == "/noclip" )
	{
		if( pPlayer.pev.movetype == MOVETYPE_NOCLIP )
		{
			pPlayer.pev.movetype = MOVETYPE_WALK;
			HubSay( pPlayer, "Noclip desactivado" );
		}
		else
		{
			pPlayer.pev.movetype = MOVETYPE_NOCLIP;
			HubSay( pPlayer, "Noclip activado" );
		}
		return true;
	}
	if( szCmd == "/armas" )
	{
		array<string> all = { "weapon_crowbar", "weapon_9mmhandgun", "weapon_357", "weapon_9mmAR", "weapon_shotgun", "weapon_crossbow",
			"weapon_rpg", "weapon_gauss", "weapon_egon", "weapon_hornetgun", "weapon_handgrenade", "weapon_satchel", "weapon_tripmine", "weapon_snark" };
		for( uint i = 0; i < all.length(); ++i )
			pPlayer.GiveNamedItem( all[ i ], 0, 0 );
		HubSay( pPlayer, "Todas las armas" );
		return true;
	}
	if( szCmd == "/give" || szCmd == "/dar" )
	{
		if( pArguments.ArgC() < 2 )
		{
			HubSay( pPlayer, "Uso: /give escopeta (crowbar pistola magnum mp5 escopeta ballesta rpg gauss egon hornet granadas satchel tripmine snarks botiquin bateria saltolargo)" );
			return true;
		}
		string szItem = HubItemName( pArguments[ 1 ] );
		if( szItem.IsEmpty() )
		{
			HubSay( pPlayer, "No conozco \"" + pArguments[ 1 ] + "\". Usa /give sin nada para ver la lista." );
			return true;
		}
		pPlayer.GiveNamedItem( szItem, 0, 0 );
		HubSay( pPlayer, "Te di " + szItem );
		return true;
	}
	if( szCmd == "/restart" || szCmd == "/reiniciar" )
	{
		g_PlayerFuncs.ClientPrintAll( HUD_PRINTTALK, "[Hub] Reiniciando el mapa...\n" );
		g_EngineFuncs.ServerCommand( "restart\n" );
		return true;
	}
	if( szCmd == "/map" || szCmd == "/mapa" )
	{
		if( pArguments.ArgC() < 2 || !HubSafeToken( pArguments[ 1 ] ) || !g_EngineFuncs.IsMapValid( pArguments[ 1 ] ) )
		{
			HubSay( pPlayer, "Uso: /map hl_c05_a1  (ese mapa no existe o el nombre no es valido)" );
			return true;
		}
		g_PlayerFuncs.ClientPrintAll( HUD_PRINTTALK, "[Hub] Cambiando a " + pArguments[ 1 ] + "...\n" );
		g_EngineFuncs.ServerCommand( "changelevel " + pArguments[ 1 ] + "\n" );
		return true;
	}
	if( szCmd == "/gravedad" )
	{
		if( pArguments.ArgC() >= 2 && pArguments[ 1 ] == "baja" )         { g_EngineFuncs.ServerCommand( "sv_gravity 200\n" ); HubSay( pPlayer, "Gravedad baja" ); }
		else if( pArguments.ArgC() >= 2 && pArguments[ 1 ] == "normal" )  { g_EngineFuncs.ServerCommand( "sv_gravity 800\n" ); HubSay( pPlayer, "Gravedad normal" ); }
		else HubSay( pPlayer, "Uso: /gravedad baja | normal" );
		return true;
	}
	if( szCmd == "/velocidad" )
	{
		if( pArguments.ArgC() >= 2 && pArguments[ 1 ] == "rapida" )       { g_EngineFuncs.ServerCommand( "sv_maxspeed 640\n" ); HubSay( pPlayer, "Velocidad x2" ); }
		else if( pArguments.ArgC() >= 2 && pArguments[ 1 ] == "normal" )  { g_EngineFuncs.ServerCommand( "sv_maxspeed 320\n" ); HubSay( pPlayer, "Velocidad normal" ); }
		else HubSay( pPlayer, "Uso: /velocidad rapida | normal" );
		return true;
	}
	if( szCmd == "/respawn" )
	{
		int s = pArguments.ArgC() >= 2 ? HubParseInt( pArguments[ 1 ] ) : -1;
		if( s < 0 || s > 60 )
		{
			HubSay( pPlayer, "Uso: /respawn 5  (segundos, de 0 a 60)" );
			return true;
		}
		g_EngineFuncs.ServerCommand( "mp_respawndelay " + s + "\n" );
		HubSay( pPlayer, "Reaparicion: " + s + " s" );
		return true;
	}
	return false;
}

HookReturnCode HubOnSay( SayParameters@ pParams )
{
	const CCommand@ pArguments = pParams.GetArguments();
	if( pArguments.ArgC() < 1 )
		return HOOK_CONTINUE;

	// (no se comprueba el primer caracter: HubHandle devuelve false para todo lo que no sea un comando suyo)
	string szFirst = pArguments[ 0 ];
	if( szFirst.Length() < 2 )
		return HOOK_CONTINUE;

	if( HubHandle( pParams.GetPlayer(), pArguments ) )
	{
		pParams.ShouldHide = true;
		return HOOK_HANDLED;
	}
	return HOOK_CONTINUE;
}
