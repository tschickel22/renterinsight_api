# Factory Direct Homes Center - FB Lead Import
# 154 leads from Kyle_FB_Leads_3_19_2026.csv
# Company ID: 4, Location ID: 7

company = Company.find(4)
puts "Company: #{company.name} (ID: #{company.id})"

# Find or create source
source = company.sources.find_or_create_by!(name: 'FB Paid')
puts "Source: #{source.name} (ID: #{source.id})"

# Check existing lead count
existing_count = company.leads.where(location_id: 7).count
puts "Existing leads in location 7: #{existing_count}"
puts ""

leads_data = [
  ['Annette', '', 'aemmert@comcast.net', '3174889599', '03/18/2026 6:54pm'],
  ['Christina', 'Montalvo', 'montalvotina@gmail.com', '6162919628', '03/18/2026 4:17am'],
  ['Jody', 'Clements Clements', 'gloriajoclements@gmail.com', '8127662859', '03/17/2026 9:12pm'],
  ['Lynn', 'Devereaux', 'lynnferren@yahoo.com', '4403099027', '03/17/2026 7:40pm'],
  ['Martin', 'Fay', 'martinfay@mac.com', '7402851627', '03/17/2026 4:42pm'],
  ['Ed', 'Galloway', 'egallo5666@faol.com', '3307736346', '03/17/2026 12:44pm'],
  ['Martha', 'Drumm', 'marthadrumm25512@gmail.com', '3046383950', '03/17/2026 11:49am'],
  ['Victoria', 'Dillon', 'mattvickydillon521@gmail.com', '9373445572', '03/17/2026 11:09am'],
  ['Brian', 'Vit', 'btvrun1@aol.com', '4196993226', '03/17/2026 10:02am'],
  ['Nancy', 'Mohr', 'nancjmohr@yahoo.com', '7246510985', '03/16/2026 7:12pm'],
  ['Shirley', 'Fox-Simon', 'cochisefx01@yahoo.com', '5866123137', '03/16/2026 6:56pm'],
  ['Chuck', 'Topper', 'chucknterri2010@gmail.com', '8127812744', '03/16/2026 6:06pm'],
  ['Wanda', 'Wiseley', 'wwisebear2@yahoo.com', '2172940006', '03/16/2026 4:30pm'],
  ['Pao', 'Xiong', 'pxiong2009@gmail.com', '9162305652', '03/16/2026 2:47pm'],
  ['Danielle', 'Cox', 'dcox5836@gmail.com', '7408233316', '03/16/2026 10:13am'],
  ['Tina', 'Sauber', 'Tinasauberspencer@gmail.com', '5173923871', '03/16/2026 7:20am'],
  ['Lori', 'Wilson', 'Slwils@twc.com', '8126776555', '03/15/2026 5:49pm'],
  ['Bethany', 'Mitchell-Neal', 'Birchfields4@yahoo.com', '7404466594', '03/15/2026 3:57pm'],
  ['Richard', 'Spearow', 'rtroublemkr@yahoo.com', '6052144191', '03/15/2026 12:53pm'],
  ['Susan', 'Casey', 'caseydanny963@gmail.com', '4196067227', '03/15/2026 12:23pm'],
  ['Kelly', 'Gaddis', 'kgaddis73@outlook.com', '2194131274', '03/15/2026 7:07am'],
  ['Denise', 'Stokes-McLain', 'denisemclain9@gmail.com', '2315702355', '03/14/2026 3:53pm'],
  ['Jamie', 'Hinz', 'hinz@stalschoolbg.org', '4195555555', '03/13/2026 11:01pm'],
  ['Chris', 'Schwartz', 'cwschwartz64@gmail.com', '2319032000', '03/13/2026 3:34pm'],
  ['Julia', 'Adams', 'juliasbrainerd@gmail.com', '3179411610', '03/13/2026 1:41am'],
  ['Vanetta', 'Wilson', 'vanetta2k6@yahoo.com', '4137994435', '03/12/2026 9:15pm'],
  ['Vicky', 'Fantozzi', 'anewlifehere21@gmail.com', '7405650482', '03/12/2026 6:32pm'],
  ['Jimmie', 'hoggard', 'hoggardjimmie@gmail.comm', '8125964508', '03/12/2026 3:55pm'],
  ['James', 'R Wilburn', 'radarsoundentertainment@yahoo.com', '3302076040', '03/12/2026 2:08pm'],
  ['Becky', 'Hamacher Thompson', 'bobbygirl1044@sbcglobal.net', '6167842521', '03/12/2026 11:39am'],
  ['Beverly', 'WhitIer', 'becerlywhitler@gmail.com', '8128202358', '03/12/2026 10:49am'],
  ['Mary', 'Lee', '719leemary1@gmail.com', '8128650793', '03/12/2026 7:28am'],
  ['Courtney', 'Taylor', 'coryt420@gmail.com', '7272420590', '03/12/2026 4:12am'],
  ['Jana', 'Michalik', 'Janamichalik@yahoo.com', '3304248470', '03/12/2026 12:45am'],
  ['Daphana', 'DeJarnette', 'deedeedejarnette24@gmail.com', '3303719253', '03/11/2026 7:46pm'],
  ['Lesia', 'Lanet Guerin-Smith', 'weezy3313@comcast.net', '8159970631', '03/11/2026 9:52am'],
  ['David', 'T. Moore Sr.', 'davidtmooresr@yahoo.com', '6145967814', '03/11/2026 7:35am'],
  ['Tamara', 'Thompson', 'cpc.cleveland@gmail.com', '6788561272', '03/11/2026 5:35am'],
  ['Chris', 'Alverson', 'calvers1@yahoo.com', '8103438914', '03/10/2026 7:29pm'],
  ['Connie', 'Williams', 'keesluvrabby@yahoo.com', '3173549702', '03/10/2026 5:46pm'],
  ['Yvonna', 'Myers Schilt', 'yschilt4@gmail.com', '5029317197', '03/10/2026 5:30pm'],
  ['Rich', 'Suits', 'catbraindogpinky@yahoo.com', '5183311094', '03/10/2026 4:52pm'],
  ['Corkie', 'Carlson', 'Corkiesue.carlson2@aol.com', '2312861366', '03/10/2026 2:45pm'],
  ['Kimberly', 'Staley', 'kcs22557@gmail.com', '8129271156', '03/10/2026 2:44pm'],
  ['Tanya', 'Taylor Stines', 'tanya0414@yahoo.com', '7349727115', '03/10/2026 1:52pm'],
  ['Chastity', 'gibson', 'Anointedfoodsandspices@gmail.com', '7345762680', '03/10/2026 10:30am'],
  ['Joe', 'Slade', 'joeytcmi637@gmail.com', '2314092190', '03/10/2026 6:46am'],
  ['Patrice', 'willis', 'Patricewillis48@gmail.com', '2164402830', '03/09/2026 9:20pm'],
  ['Joseph', 'Lewis', 'jlojmj@ameritech.net', '7733387943', '03/09/2026 5:27pm'],
  ['Lisa', 'Byrd', 'grantlisa5353@gmail.com', '3132086552', '03/09/2026 12:11pm'],
  ['Kristi', 'South', 'southlynn75@gmail.com', '6145717029', '03/09/2026 10:49am'],
  ['Brian', 'Johnson', 'theracersedge396@msn.com', '2604433370', '03/08/2026 7:14pm'],
  ['Sarah', 'Moore', 'msmoore2000@gmail.com', '6188017029', '03/08/2026 4:30pm'],
  ['Nicholas', 'Arra', 'nick.arra80@gmail.com', '4407242584', '03/08/2026 9:55am'],
  ['Debbie', 'Humes', 'dhumes@centurylink.net', '5748065733', '03/08/2026 9:21am'],
  ['Mariah', 'Krider', 'makrider2024@gmail.com', '2605034831', '03/08/2026 9:17am'],
  ['Amanda', 'Han', 'ruitong.han20@gmail.com', '8015730087', '03/07/2026 10:28pm'],
  ['Deb', 'Jackson', 'debi.jackson1972@gmail.com', '9892741750', '03/07/2026 1:24pm'],
  ['Kim', 'Wheeler- Talmage', 'talmagekim@yahoo.com', '2697188931', '03/07/2026 11:51am'],
  ['Mary', 'Sarianides', 'leadplar@yahoo.com', '3308075854', '03/07/2026 10:30am'],
  ['Lee', 'Boykin', 'leeboykin22@gmail.com', '2482590612', '03/06/2026 9:09pm'],
  ['Nichole', 'Czerkies', 'nikkitickner5@gmail.com', '9896409522', '03/06/2026 6:11pm'],
  ['Stanley', 'Kempke Jr.', 'Stoshu312@gmail.com', '6164023012', '03/06/2026 5:11pm'],
  ['Jerry', 'Grogan', 'jerrygrogan8@gmail.com', '5135100138', '03/06/2026 3:50pm'],
  ['Tim', 'Sibbitt', 'tim@tomsibbitt.com', '8125930177', '03/06/2026 2:14am'],
  ['Matthew', 'Stanfield', 'matt.stanfield@hotmail.com', '5675259748', '03/05/2026 6:16pm'],
  ['Francesca', 'Caporale Gould', 'Gaggleofgould@yahoo.com', '5136733006', '03/05/2026 6:02pm'],
  ['Michelle', 'Fox-Corey', 'catelle01@yahoo.com', '9893722893', '03/05/2026 5:48pm'],
  ['Deborah', 'Brinkman', 'dbrinkmanmikey@gmail.com', '2162528760', '03/05/2026 9:49am'],
  ['Kelly', 'Pervine', 'Kellypervine@hotmail.com', '9896409167', '03/05/2026 5:31am'],
  ['Brad', 'Ormes', 'bradormes@yahoo.com', '7656206229', '03/05/2026 12:30am'],
  ['Teddy', 'Duneghy', 'tduneghy@tmd-solutions.com', '8126041204', '03/04/2026 7:47pm'],
  ['sherri', 'Bowman', 'sheri.l.bowman.1974@gmail.com', '3177788312', '03/04/2026 4:53pm'],
  ['Howard', 'Davis', 'Davishowardtim@gmail.com', '7089981968', '03/04/2026 4:17pm'],
  ['Nina', 'Brooks-Brown', 'teambtooksbrown5@gmail.com', '2312155578', '03/04/2026 3:29pm'],
  ['Misti', 'Oliver', 'mcail1204@gmail.com', '3306361288', '03/04/2026 11:38am'],
  ['Tina', 'Linton', 'tlinton74@yahoo.com', '7406033838', '03/04/2026 9:39am'],
  ['Jimmie', 'Bowman', 'Jimmiebowmanphhd@gmail.com', '3302098224', '03/04/2026 8:20am'],
  ['Jay', 'Chojnacki', 'jchojnacki@sbsm.com', '5135375537', '03/04/2026 7:57am'],
  ['melinda', 'middleton', 'MIssmindi818@hotmail.com', '3304662030', '03/03/2026 5:01pm'],
  ['Sandra', 'J Detar', 'sjd628@hotmail.com', '7202978727', '03/03/2026 4:33pm'],
  ['William', 'Perkins', 'wjpsmc@yahoo.com', '2694050527', '03/03/2026 4:05pm'],
  ['Hannah', 'R. Smith', 'hrs2008lchs@yahoo.com', '4192653166', '03/03/2026 3:15pm'],
  ['Brian', 'Cecil', 'bcecil69@gmail.com', '5028270275', '03/03/2026 12:20am'],
  ['Trish', 'Smith', 'patriciasmith800@comcast.net', '2192109118', '03/02/2026 10:29pm'],
  ['Jennifer', 'Carsey', 'Jc21boston@icloud.com', '6145890801', '03/02/2026 7:06pm'],
  ['Bonnie', 'Boone', 'bonnie.roseboone65@gmail.com', '6063892198', '03/02/2026 6:53am'],
  ['Brew', 'Esquivel', 'esquib1@yahoo.com', '5175128113', '03/01/2026 8:06pm'],
  ['DEAYNNE', 'T. SUTTLE', 'traccies@yahoo.com', '3177625223', '03/01/2026 4:10pm'],
  ['Marcus', 'Whitfield', 'ynvmnm1971@gmail.com', '5135518190', '03/01/2026 1:55pm'],
  ['Tricia', 'Talley', 'triciatalley@yahoo.com', '3136587196', '03/01/2026 11:56am'],
  ['Franco', 'Mejia', 'francomejis30@gmail.com', '2697675034', '03/01/2026 11:41am'],
  ['Janet', 'Wehmeyer', 'janet.wehmeyer@yahoo.com', '2194489898', '03/01/2026 6:59am'],
  ['Patricia', 'Secor', 'psecor026@gmail.com', '5742157845', '02/28/2026 9:16pm'],
  ['Harriet', 'V Blain', 'hblain2@gmail.com', '6143903876', '02/28/2026 6:04pm'],
  ['La', 'Hnat', 'Laura.hnat@roadrunner.com', '3307306681', '02/28/2026 12:26pm'],
  ['Melissa', 'Hart', 'mjhart750@hotmail.com', '7403655180', '02/28/2026 10:50am'],
  ['Tami', 'Fox', 'Foxtami10@yahoo.com', '8122604823', '02/28/2026 8:49am'],
  ['John', 'Quintano', 'johnq_58@yahoo.com', '9893708523', '02/28/2026 8:45am'],
  ['Gabriele', 'murphy', 'Gabrielemurphy@comcast.net', '2482015026', '02/28/2026 4:22am'],
  ['Leah', 'Marie', 'leahmarie7070@gmail.com', '2186868993', '02/27/2026 7:44pm'],
  ['Sondra', 'Rowe', 'Sondralee744@gmail.com', '9372959700', '02/27/2026 6:30pm'],
  ['Randy', 'Easter', 'randyeaster9@aol.com', '5135085919', '02/27/2026 6:22pm'],
  ['Jason', 'Johns', 'jasonj811@aol.com', '8126190896', '02/27/2026 10:04am'],
  ['Maureen', 'Rupert', 'drupert@gmail.com', '2194056000', '02/27/2026 1:53am'],
  ['Joanne', 'Wright', 'Kcwright0629@gmail.com', '2162948800', '02/26/2026 5:49pm'],
  ['Daneen', 'Andrews', 'ms.daneen78@gmail.com', '6165899428', '02/26/2026 5:31pm'],
  ['Shay', 'Marie', 'Shawan.herring@yahoo.com', '9378187507', '02/26/2026 4:43pm'],
  ['Don', 'Bish', 'danb113@charter.net', '9062806133', '02/26/2026 4:26pm'],
  ['Ruby', 'Wagner', 'Rubyowagner5@gmail.com', '6148248125', '02/26/2026 12:33pm'],
  ['Crystal', 'Moore', 'crystalmoore11281@gmail.com', '8128760001', '02/26/2026 9:48am'],
  ['Debbie', 'Hartley', 'dbbhrtly@yahoo.com', '4195775048', '02/26/2026 3:03am'],
  ['Rebecca', 'Shaw', 'rebecca.shaw77@yahoo.com', '5743399977', '02/26/2026 2:34am'],
  ['Tiffany', 'Ellis', 'te43207@gmail.com', '6143626205', '02/25/2026 12:29pm'],
  ['Cindy', 'Clements', 'davidmobryant@gmail.com', '9374036640', '02/25/2026 10:26am'],
  ['Beth', 'Wampler', 'bethwamp@gmail.com', '9375816198', '02/25/2026 8:11am'],
  ['Anne', 'Hertenstein', 'a.hertenstein95@gmail.com', '4199533931', '02/24/2026 8:42pm'],
  ['Alex', 'Hellier', 'alexanderjhellier@gmail.com', '3308882991', '02/24/2026 7:02pm'],
  ['Kimberly', 'D Lamb', 'kimbalamb@yahoo.com', '3134100922', '02/24/2026 1:14pm'],
  ['Michael', 'Perez', 'Perezwsm@optimum.net', '7327444399', '02/24/2026 11:22am'],
  ['Brenda', 'Rice Boecher', 'b_boecher@hotmail.com', '4196738084', '02/24/2026 10:45am'],
  ['Lavonte', 'Williams', 'lavontedwilliams@gmail.com', '2698615996', '02/24/2026 9:37am'],
  ['Grace', 'Willis', 'gracewillis128@gmail.com', '3135367475', '02/24/2026 3:45am'],
  ['John', 'Mason', 'Spike044@icloud.com', '7653663042', '02/23/2026 6:32pm'],
  ['Elizabeth', 'Denney', 'eadenney93@gmail.com', '7347179913', '02/23/2026 11:19am'],
  ['Xiomara', 'Melero', 'xiomara.melero@gmail.com', '5863397707', '02/22/2026 5:17pm'],
  ['Bertram', 'Wiggins', 'ligaf70@gmail.com', '5203104762', '02/22/2026 3:52pm'],
  ['Mrc', 'Young', 'youngmovezz@gmail.com', '3138082103', '02/22/2026 8:14am'],
  ['Mic', 'Bio', 'Drsemi19@gmail.com', '8103414945', '02/22/2026 7:30am'],
  ['Rasheida', '& Lisa Bennett', 'Rdb12777@gmail.com', '2194665098', '02/21/2026 11:29am'],
  ['Jennifer', 'Jenne', 'jenniferjenne@yahoo.com', '8454647583', '02/21/2026 6:32am'],
  ['James', 'Sedlar', 'jamessedlar@sbcglobal.net', '3137133128', '02/20/2026 8:14am'],
  ['Eric', 'Meister', 'shakerq96@gmail.com', '4406692270', '02/19/2026 6:31pm'],
  ['Jeffrey', 'Hoseclaw', 'jeffreyhoseclaw@yahoo.com', '8106143556', '02/19/2026 4:10pm'],
  ['Ivan', 'Nunez Rodriguez', 'Srivannu50@hotmail.com', '2313032501', '02/19/2026 11:18am'],
  ['Jamie', 'Hinkston', 'coleman.felicia.398@gmail.com', '5132050133', '02/19/2026 10:45am'],
  ['DOTTY', 'HERRIMAN', 'Herrimans@yahoo.com', '2696216611', '02/19/2026 2:34am'],
  ['Joanne', 'Finger', 'joannejfinger@gmail.com', '7159385668', '02/18/2026 6:18pm'],
  ['Melissa', 'McMillin', 'm.mcmillin98@gmail.com', '5022991682', '02/18/2026 3:54pm'],
  ['Mindy', 'Leann Papageorge', 'mindy.leann@hotmail.com', '7407047122', '02/18/2026 2:12pm'],
  ['Demetrius', '', 'dsimpy2002@yahoo.com', '2163235814', '02/18/2026 11:36am'],
  ['D.P.', '', 'drpuckett@yahoo.com', '8123451172', '02/18/2026 10:05am'],
  ['Judy', 'Frye Perry', 'j069p@aol.com', '6144192790', '02/18/2026 8:54am'],
  ['Justin', 'Swanson', 'swansonj62@gmail.com', '7406518892', '02/18/2026 5:09am'],
  ['Samantha', 'Brockman', 'sammy_j_17@hotmail.com', '5179142443', '02/18/2026 2:02am'],
  ['Marlena', 'Wilson', 'marlenamswilson@yahoo.com', '2316757869', '02/17/2026 10:35pm'],
  ['Joel', 'Almaroad', 'aasj@msn.com', '8127011813', '02/17/2026 6:49pm'],
  ['Melissa', 'Pitman', 'melissapitman@yahoo.com', '2602240020', '02/17/2026 3:42pm'],
  ['Kelly', 'Petro-Fuller', 'kellyfuller1981@gmail.com', '8127640085', '02/17/2026 3:00pm'],
  ['Rose', 'Daugherty', 'nanarose6563@gmail.com', '7402281533', '02/17/2026 2:51pm'],
  ['Lesi', 'Casey Key', 'lesikey68@gmail.com', '8128204168', '02/17/2026 9:58am'],
  ['Roger', 'Budnick', 'rrnabudnick@gmail.com', '9893064537', '02/17/2026 9:17am'],
  ['Claudio', 'Nappo', 'claudionappo@gmail.com', '4404876009', '02/17/2026 7:42am'],
  ['Bill', 'Stock', 'rapid933@yahoo.com', '8593041792', '02/17/2026 7:18am']
]

puts "Processing #{leads_data.length} leads..."
puts ""

created_count = 0
skipped_count = 0
error_count = 0

leads_data.each_with_index do |row, idx|
  first_name, last_name, email, phone, created_at_str = row

  # Check for duplicate by email within this company
  if email.present? && company.leads.where(email: email).exists?
    skipped_count += 1
    puts "  SKIP (dup email): #{first_name} #{last_name} - #{email}" if skipped_count <= 10
    next
  end

  # Parse created date
  begin
    lead_date = DateTime.strptime(created_at_str, '%m/%d/%Y %I:%M%p') rescue Time.current
  rescue
    lead_date = Time.current
  end

  lead = company.leads.build(
    first_name: first_name.presence || 'Unknown',
    last_name: last_name.presence,
    email: email,
    phone: phone.present? ? phone : nil,
    source_id: source.id,
    location_id: 7,
    status: 'new',
    notes: "Imported from Facebook Leads CSV (3/19/2026)",
    created_at: lead_date,
    updated_at: lead_date
  )

  if lead.save
    created_count += 1
  else
    error_count += 1
    puts "  ERROR: #{first_name} #{last_name} - #{lead.errors.full_messages.join(', ')}" if error_count <= 10
  end
end

puts ""
puts "========== IMPORT COMPLETE =========="
puts "Created: #{created_count}"
puts "Skipped (duplicate): #{skipped_count}"
puts "Errors: #{error_count}"
puts "New total leads in location 7: #{company.leads.where(location_id: 7).count}"
