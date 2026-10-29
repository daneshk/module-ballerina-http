// Copyright (c) 2026 WSO2 Inc. (http://www.wso2.org) All Rights Reserved.
//
// WSO2 Inc. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/http;
import ballerina/test;
import ballerina/time;

listener http:Listener retryAfterBackendListener = new (retryAfterTestPort, httpVersion = http:HTTP_1_1);

final http:Client retryAfterClient = check new ("http://localhost:" + retryAfterTestPort.toString(),
    httpVersion = http:HTTP_1_1,
    retryConfig = {
        count: 2,
        interval: 1,
        backOffFactor: 1.0,
        maxWaitInterval: 5,
        statusCodes: [429]
    }
);

isolated map<int> retryAfterHits = {};

isolated function recordRetryAfterHit(string mode) returns int {
    lock {
        int hits = (retryAfterHits[mode] ?: 0) + 1;
        retryAfterHits[mode] = hits;
        return hits;
    }
}

isolated function getRetryAfterHits(string mode) returns int {
    lock {
        return retryAfterHits[mode] ?: 0;
    }
}

// Responds with 429 and a `Retry-After` value chosen by the mode on the first call, and 200 afterwards.
service /retryAfterBackend on retryAfterBackendListener {
    resource function get [string mode]() returns http:Response|error {
        http:Response res = new;
        if recordRetryAfterHit(mode) > 1 {
            res.statusCode = http:STATUS_OK;
            res.setTextPayload("OK");
            return res;
        }
        res.statusCode = http:STATUS_TOO_MANY_REQUESTS;
        match mode {
            "seconds" => {
                res.setHeader("Retry-After", "3");
            }
            "date" => {
                time:Utc retryTime = time:utcAddSeconds(time:utcNow(), 5);
                res.setHeader("Retry-After", check time:utcToEmailString(retryTime));
            }
            "pastDate" => {
                res.setHeader("Retry-After", "Wed, 21 Oct 2015 07:28:00 GMT");
            }
            "invalid" => {
                res.setHeader("Retry-After", "soon");
            }
            "tooLong" => {
                res.setHeader("Retry-After", "100");
            }
        }
        return res;
    }
}

function callRetryAfterBackend(string mode) returns [http:Response, decimal]|error {
    time:Utc startTime = time:utcNow();
    http:Response res = check retryAfterClient->get("/retryAfterBackend/" + mode);
    return [res, time:utcDiffSeconds(time:utcNow(), startTime)];
}

@test:Config {
    groups: ["retryClientTest", "retryAfter"]
}
function testRetryAfterDeltaSeconds() returns error? {
    var [res, elapsed] = check callRetryAfterBackend("seconds");
    test:assertEquals(res.statusCode, 200);
    test:assertEquals(getRetryAfterHits("seconds"), 2);
    // Configured interval is 1s, so waiting at least ~3s shows the header was honored.
    test:assertTrue(elapsed >= 2.9d, "Retry-After seconds was not honored, waited " + elapsed.toString());
}

@test:Config {
    groups: ["retryClientTest", "retryAfter"]
}
function testRetryAfterHttpDate() returns error? {
    var [res, elapsed] = check callRetryAfterBackend("date");
    test:assertEquals(res.statusCode, 200);
    test:assertEquals(getRetryAfterHits("date"), 2);
    // The HTTP-date has one second resolution, so allow for truncation.
    test:assertTrue(elapsed >= 3d, "Retry-After date was not honored, waited " + elapsed.toString());
}

@test:Config {
    groups: ["retryClientTest", "retryAfter"]
}
function testRetryAfterExceedingMaxWaitInterval() returns error? {
    var [res, elapsed] = check callRetryAfterBackend("tooLong");
    test:assertEquals(res.statusCode, 429);
    test:assertEquals(getRetryAfterHits("tooLong"), 1);
    test:assertTrue(elapsed < 1d, "Client should return the 429 without waiting, waited " + elapsed.toString());
}

@test:Config {
    groups: ["retryClientTest", "retryAfter"]
}
function testRetryAfterPastDateFallsBackToInterval() returns error? {
    var [res, elapsed] = check callRetryAfterBackend("pastDate");
    test:assertEquals(res.statusCode, 200);
    test:assertEquals(getRetryAfterHits("pastDate"), 2);
    test:assertTrue(elapsed >= 0.9d && elapsed < 2.5d, "Expected the configured interval, waited " + elapsed.toString());
}

@test:Config {
    groups: ["retryClientTest", "retryAfter"]
}
function testRetryAfterInvalidValueFallsBackToInterval() returns error? {
    var [res, elapsed] = check callRetryAfterBackend("invalid");
    test:assertEquals(res.statusCode, 200);
    test:assertEquals(getRetryAfterHits("invalid"), 2);
    test:assertTrue(elapsed >= 0.9d && elapsed < 2.5d, "Expected the configured interval, waited " + elapsed.toString());
}

@test:Config {
    groups: ["retryClientTest", "retryAfter"]
}
function testRetryOn429WithoutRetryAfterHeader() returns error? {
    var [res, elapsed] = check callRetryAfterBackend("none");
    test:assertEquals(res.statusCode, 200);
    test:assertEquals(getRetryAfterHits("none"), 2);
    test:assertTrue(elapsed >= 0.9d && elapsed < 2.5d, "Expected the configured interval, waited " + elapsed.toString());
}
