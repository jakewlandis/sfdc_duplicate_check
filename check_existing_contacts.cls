public with sharing class CheckExistingContacts {
    
    // define the strings to be used to match against the match rule for contact
    public class intake_contact { //all variables accessibility public since need access to them from outer APIs
        public String row = '';
        public String requestedRecId = ''; //requested record's identifier to be carried through matching process
        public String first = '';
        public String middle = '';
        public String last = '';
        public String email = '';
        public String street = '';
        public String zip = '';
        public String phone = '';
        public String SFID = '';
        public String ext = '';
        public Decimal confidence = 0;
        public String SFID2 = '';
        public String ext2 = '';
        public Decimal confidence2 = 0;
    }

    // matching rule comparisons are limited to batches of 50, so we need to create a list of 50 record collections
    public class full_csv {
        List<List<intake_contact>> csv_batch;
    }

    // sample json below -- useful if processing data via integration instead of via a CSV file
    /*
    [
        {
            "Row #": "1",
            "requestedRecId": "XYZ123",
            "First": "Person",
            "Middle": "W",
            "Last": "Person2",
            "Email": "test@georgetown.edu",
            "Street": "222 Hoya Ave",
            "Zip": "22303",
            "Netid": "jwl43",
            "Phone": "3019968996"
        },
        {
            "Row #": "2",
            "requestedRecId": "XYZ123",
            "First": "Individual",
            "Middle": "F",
            "Last": "Individual2",
            "Email": "test@georgetown.edu",
            "Street": "123 Fake St",
            "Zip": "17406",
            "Netid": "jwl43",
            "Phone": "3012049212"
        }
    ]
    */

    @AuraEnabled
    public static List<intake_contact> checkContactMatch(String jsonfromfile, String matchingrulename, Boolean emailResults) {

        //jsonfromfile is the string that contains your contact data
        //matchrulename is the API name of your Salesforce Matching Rules used for duplicate comparison
        //emailResults is a boolean that determines whether or not the results of the duplicate check are emailed to the running user

        // deserialize the json into the defined class
        List<intake_contact> datalist = (List<intake_contact>) JSON.deserialize(jsonfromfile, List<intake_contact>.class);

        if (datalist.size() > 5000){ //above this number of intake records, we noticed slowdown / failures so we split into multiple results
  
            // move to batch execution instead of single call
            full_csv f = new full_csv();
            f.csv_batch = new List<List<intake_contact>>();

            integer batches_needed = 0;

            // check to see how many iterations of dupe check will be necessary
            if (math.mod(datalist.size(), 500) > 0){
                batches_needed = (datalist.size() / 500) + 1;
            } else {
                batches_needed = (datalist.size() / 500);
            } 

            for (integer i=0; i < batches_needed; i++){
                List<intake_contact> single_batch = new List<intake_contact>();
                f.csv_batch.add(single_batch);
            }

            integer batch_count_csv = 0;

            while (batches_needed > 0){
                // iterate through the 500 objects in the list
                for (Integer i=0; i<500; i++){
                    if (((batch_count_csv * 500)+i) < datalist.size()){
                        f.csv_batch[batch_count_csv].add(datalist[(batch_count_csv * 500)+i]);
                    }
                }
                batch_count_csv++;
                batches_needed--;
            }
            if (!Test.isRunningTest()){
                Id jobId = Database.executeBatch(new GU360_Duplicate_Contact_Batch(f.csv_batch, matchingrulenames, emailResults), 1);
            } else {
                full_csv one_f = new full_csv();
            	one_f.csv_batch = new List<List<intake_contact>>();
                one_f.csv_batch.add(f.csv_batch[0]);
                Id jobId = Database.executeBatch(new GU360_Duplicate_Contact_Batch(one_f.csv_batch, matchingrulenames, emailResults), 1);
            }
            return datalist;
        } else {
            //if datalist size > 50 split into batches
            datalist = processContacts(datalist, matchingrulenames, emailResults);
            return datalist;
        }
    }

    @AuraEnabled
    public static List<intake_contact> processContacts(List<intake_contact> datalist, List<String> matchingrulenames, Boolean emailResults) {
        //instantiate the list of batches
        full_csv f = new full_csv();
        //instantiate the first batch
        f.csv_batch = new List<List<intake_contact>>();

        if (datalist.size() > 50){
                
            integer loops_needed = 0;

            // check to see how many iterations of dupe check will be necessary
            if (math.mod(datalist.size(), 50) > 0){
                loops_needed = (datalist.size() / 50) + 1;
                system.debug('loops needed: ' + loops_needed);
            } else {
                loops_needed = (datalist.size() / 50);
                system.debug('loops needed: ' + loops_needed);
            } 

            // construct the list of batches
            for (integer i=0; i < loops_needed; i++){
                List<intake_contact> single_batch = new List<intake_contact>();
                f.csv_batch.add(single_batch);
            }

            integer loop_count_csv = 0;
            
            // iterate through the number of loops needed
            while (loops_needed > 0){
                
                // iterate through the 50 objects in the list
                for (Integer i=0; i<50; i++){
                    
                    if (((loop_count_csv * 50)+i) < datalist.size()){
                        f.csv_batch[loop_count_csv].add(datalist[(loop_count_csv * 50)+i]);
                    }
                
                }
                loop_count_csv++;
                loops_needed--;
            }
        } else {
            List<intake_contact> single_batch = new List<intake_contact>();
            f.csv_batch.add(single_batch);
            for (Integer i=0; i<datalist.size(); i++){ 
                f.csv_batch[0].add(datalist[i]);
            }
        }

        // prep a list of contacts in salesforce format to introduce to the match rule
        List<Contact> new_contacts = new List<Contact>();
        // create maps to make sure we can put the result of the matching rule back on the correct row of the input data
        Map<Integer, String> rowMap = new Map<Integer, String>();
        Map<Integer, Decimal> rowConfidence = new Map<Integer, Decimal>();
        Map<Integer, String> rowMap2 = new Map<Integer, String>();
        Map<Integer, Decimal> rowConfidence2 = new Map<Integer, Decimal>();
        integer row_position = 0;
        integer loop_position = 0;

        // the string that will be converted back to json/csv
        string finalstr;

        // look through the contents to create the contact list
        for (List<intake_contact> dupeloop : f.csv_batch){
            
            // clear the list for each batch
            new_contacts.clear();
            integer dupeloopint = 0;
            string netid_derived;
            Integer at_sign;

            for (intake_contact i: dupeloop){
                Contact c = new Contact();
                
                // this criteria prevents the duplicate rule (which is strict) from being run outside of this context
                c.DataSource__c = 'DUPECHECK';
                if (i.first != null){
                    c.firstname = i.first;
                }
                if (i.middle != null){
                    c.middlename = i.middle;
                }
                if (i.last != null){
                    c.lastname = i.last;
                }
                if (i.email != null){
                    c.Email = i.email;
                }
                if (i.street != null){
                    c.mailingstreet = i.street;
                }
                if (i.zip != null){
                    c.mailingpostalcode = i.zip;
                }
                if (i.phone != null){
                    c.phone = i.phone;
                }
                new_contacts.add(c);
                dupeloopint++;
            }
			System.debug(Limits.getCpuTime());
            // this is the magic stuff -- salesforce provides these methods to access the dupe results
            // note that we are sorting out results from other dupe checks
            List<Datacloud.FindDuplicatesResult> results = Datacloud.FindDuplicates.findDuplicates(new_contacts);

            integer iresults = 0;
			System.debug(Limits.getCpuTime());
            for (Datacloud.FindDuplicatesResult findDupeResult : results) {
                iresults++;
                 System.debug(iresults);
                System.debug(Limits.getCpuTime());
                for (Datacloud.DuplicateResult dupeResult : findDupeResult.getDuplicateResults()) {
                    if (dupeResult.getDuplicateRule() == matchingrulenames[0]){
                        for (Datacloud.MatchResult matchResult : dupeResult.getMatchResults()) {
                            for (Datacloud.MatchRecord matchRecord : matchResult.getMatchRecords()) {
                                System.debug('@@@Duplicate Record: ' + matchRecord.getRecord());
                                System.debug('@@@Dupe Record ID: ' + matchRecord.getRecord().id);
                                rowMap.put(((loop_position * 50) +iresults), matchRecord.getRecord().id);
                                rowConfidence.put(((loop_position * 50) +iresults), matchRecord.getMatchConfidence());
                            }
                        }
                    } else if (dupeResult.getDuplicateRule() == matchingrulenames[1]){
                        for (Datacloud.MatchResult matchResult : dupeResult.getMatchResults()) {
                            for (Datacloud.MatchRecord matchRecord : matchResult.getMatchRecords()) {
                                rowMap2.put(((loop_position * 50) +iresults), matchRecord.getRecord().id);
                                rowConfidence2.put(((loop_position * 50) +iresults), matchRecord.getMatchConfidence());
                            }
                        }
                    }
                }
            }
            
            loop_position++;
        }
        
        Map<String, Integer> id_to_row = new Map<String, Integer>();
        Map<String, Integer> id_to_row2 = new Map<String, Integer>();
        Map<Integer, String> rowExt = new Map<Integer, String>();
        Map<Integer, String> rowExt2 = new Map<Integer, String>();
        for (Integer idKey : rowMap.keyset()){
            id_to_row.put(rowMap.get(idKey), idKey);
        }
        for (Integer idKey : rowMap2.keyset()){
            id_to_row2.put(rowMap2.get(idKey), idKey);
        }

        List<Contact> matches = [SELECT Id, AQB__ContactExternalID__c FROM Contact WHERE Id IN :id_to_row.keyset()];
        for (Contact c : matches){
            rowExt.put(id_to_row.get(c.id), c.AQB__ContactExternalID__c);
        }
        List<Contact> matches2 = [SELECT Id, AQB__ContactExternalID__c FROM Contact WHERE Id IN :id_to_row2.keyset()];
        for (Contact c : matches2){
            rowExt2.put(id_to_row2.get(c.id), c.AQB__ContactExternalID__c);
        }

        string header = 'Row #,First,Middle,Last,Email,Street,Zip,Phone,Name+1 SFID,Name+1 Ext,Name+1 Score,Wild Guess SFID,Wild Guess Ext\n';
        if (row_position == 0){
            finalstr = header ;
        }
        
        integer rowcount = 1;
        
        // reconstruct the csv data but now include the columns for id and confidence

        for (intake_contact i: datalist)
        {
            String row;
            String first;
            String middle;
            String last;
            String email;
            String street;
            String zip;
            String phone;
            String returned_id;
            String external_id;
            decimal returned_confidence;
            String returned_id2;
            String external_id2;
            decimal returned_confidence2;
            
            //system.debug('Reassembly Rowcount: ' + rowcount);
            
            if (i.first == null){
                first = '';
            } else {
                first = i.first;
            }
            if (i.middle == null){
                middle = '';
            } else {
                middle = i.middle;
            }
            if (i.last == null){
                last = '';
            } else {
                last = i.last;
            }
            if (i.email == null){
                email = '';
            } else {
                email = i.email;
            }
            if (i.street == null){
                street = '';
            } else {
                street = i.street;
            }
            if (i.zip == null){
                zip = '';
            } else {
                zip = i.zip;
            }
            if (i.phone == null){
                phone = '';
            } else {
                phone = i.phone;
            }
            if (rowMap.get(rowcount) == null){
                returned_id = '';
                i.SFID = '';
            } else {
                returned_id = rowMap.get(rowcount);
                i.SFID = rowMap.get(rowcount);
            }
            if (rowExt.get(rowcount) == null){
                external_id = '';
                i.ext = '';
            } else {
                external_id = rowExt.get(rowcount);
                i.ext = rowExt.get(rowcount);
            }
            if (rowConfidence.get(rowcount) == null){
                returned_confidence = 0;
                i.confidence = 0;
            } else {
                returned_confidence = rowConfidence.get(rowcount);
                i.confidence = rowConfidence.get(rowcount);
            }
            
            //match 2
            system.debug('fetching sfid2 for row: ' + rowcount);
            if (rowMap2.get(rowcount) == null){
                returned_id2 = '';
                i.SFID2 = '';
            } else {
                returned_id2 = rowMap2.get(rowcount);
                i.SFID2 = rowMap2.get(rowcount);
            }
            system.debug('fetching external id for row: ' + rowcount);
            if (rowExt2.get(rowcount) == null){
                external_id2 = '';
                i.ext2 = '';
            } else {
                external_id2 = rowExt2.get(rowcount);
                i.ext2 = rowExt2.get(rowcount);
            }
            
            string recordString = '"'+rowcount+'","'+first+'","'+middle+'","'+last+'","'+email+'","'+street+'","'+zip+'","'+phone+'","'+returned_id+'","'+external_id+'","'+returned_confidence+'","'+returned_id2+'","'+external_id2+'"\n';
            finalstr = finalstr +recordString;
            rowcount++;
        }
        
        new_contacts.clear();

        // email the results to the active user
        if (emailResults == true){
            Messaging.EmailFileAttachment csvAttc = new Messaging.EmailFileAttachment();
            blob csvBlob = Blob.valueOf(finalstr);
            string csvname= 'Matches.csv';
            csvAttc.setFileName(csvname);
            csvAttc.setBody(csvBlob);
            Messaging.SingleEmailMessage email =new Messaging.SingleEmailMessage();
            String emailAddress = UserInfo.getUserEmail();
            String[] toAddresses = new list<string> {emailAddress};
            String subject ='Duplicate Check CSV';
            email.setSubject(subject);
            email.setToAddresses( toAddresses );
            email.setPlainTextBody('Duplicate Check CSV ');
            email.setFileAttachments(new Messaging.EmailFileAttachment[]{csvAttc});
            Messaging.SendEmailResult [] r = Messaging.sendEmail(new Messaging.SingleEmailMessage[] {email});
        }

        return datalist;
    }
}
